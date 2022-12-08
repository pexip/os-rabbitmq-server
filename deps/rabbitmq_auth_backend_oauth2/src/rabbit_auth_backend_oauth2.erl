%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_auth_backend_oauth2).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([description/0]).
-export([user_login_authentication/2, user_login_authorization/2,
         check_vhost_access/3, check_resource_access/4,
         check_topic_access/4, check_token/1, state_can_expire/0, update_state/2]).

% for testing
-export([post_process_payload/1]).

-import(rabbit_data_coercion, [to_map/1]).

-ifdef(TEST).
-compile(export_all).
-endif.

%%
%% App environment
%%

-type app_env() :: [{atom(), any()}].

-define(APP, rabbitmq_auth_backend_oauth2).
-define(RESOURCE_SERVER_ID, resource_server_id).
%% a term used by the IdentityServer community
-define(COMPLEX_CLAIM_APP_ENV_KEY, extra_scopes_source).
%% scope aliases map "role names" to a set of scopes
-define(SCOPE_MAPPINGS_APP_ENV_KEY, scope_aliases).

%%
%% Key JWT fields
%%

-define(AUD_JWT_FIELD, <<"aud">>).
-define(SCOPE_JWT_FIELD, <<"scope">>).

%%
%% API
%%

description() ->
    [{name, <<"OAuth 2">>},
     {description, <<"Performs authentication and authorisation using JWT tokens and OAuth 2 scopes">>}].

%%--------------------------------------------------------------------

user_login_authentication(Username, AuthProps) ->
    case authenticate(Username, AuthProps) of
	{refused, Msg, Args} = AuthResult ->
	    rabbit_log:debug(Msg, Args),
	    AuthResult;
	_ = AuthResult ->
	    AuthResult
    end.

user_login_authorization(Username, AuthProps) ->
    case authenticate(Username, AuthProps) of
        {ok, #auth_user{impl = Impl}} -> {ok, Impl};
        Else                          -> Else
    end.

check_vhost_access(#auth_user{impl = DecodedToken},
                   VHost, _AuthzData) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes      = get_scopes(DecodedToken),
            ScopeString = rabbit_oauth2_scope:concat_scopes(Scopes, ","),
            rabbit_log:debug("Matching virtual host '~s' against the following scopes: ~s", [VHost, ScopeString]),
            rabbit_oauth2_scope:vhost_access(VHost, Scopes)
        end).

check_resource_access(#auth_user{impl = DecodedToken},
                      Resource, Permission, _AuthzContext) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:resource_access(Resource, Permission, Scopes)
        end).

check_topic_access(#auth_user{impl = DecodedToken},
                   Resource, Permission, Context) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:topic_access(Resource, Permission, Context, Scopes)
        end).

state_can_expire() -> true.

update_state(AuthUser, NewToken) ->
  case check_token(NewToken) of
      %% avoid logging the token
      {error, _} = E  -> E;
      {refused, {error, {invalid_token, error, _Err, _Stacktrace}}} ->
        {refused, "Authentication using an OAuth 2/JWT token failed: provided token is invalid"};
      {refused, Err} ->
        {refused, rabbit_misc:format("Authentication using an OAuth 2/JWT token failed: ~p", [Err])};
      {ok, DecodedToken} ->
          Tags = tags_from(DecodedToken),

          {ok, AuthUser#auth_user{tags = Tags,
                                  impl = DecodedToken}}
  end.

%%--------------------------------------------------------------------

authenticate(Username0, AuthProps0) ->
    AuthProps = to_map(AuthProps0),
    Token     = token_from_context(AuthProps),
    case check_token(Token) of
        %% avoid logging the token
        {error, _} = E  -> E;
        {refused, {error, {invalid_token, error, _Err, _Stacktrace}}} ->
          {refused, "Authentication using an OAuth 2/JWT token failed: provided token is invalid", []};
        {refused, Err} ->
          {refused, "Authentication using an OAuth 2/JWT token failed: ~p", [Err]};
        {ok, DecodedToken} ->
            Func = fun() ->
                        Username = username_from(Username0, DecodedToken),
                        Tags     = tags_from(DecodedToken),

                        {ok, #auth_user{username = Username,
                                        tags = Tags,
                                        impl = DecodedToken}}
                   end,
            case with_decoded_token(DecodedToken, Func) of
                {error, Err} ->
                    {refused, "Authentication using an OAuth 2/JWT token failed: ~p", [Err]};
                Else ->
                    Else
            end
    end.

with_decoded_token(DecodedToken, Fun) ->
    case validate_token_expiry(DecodedToken) of
        ok               -> Fun();
        {error, Msg} = Err ->
            rabbit_log:error(Msg),
            Err
    end.

validate_token_expiry(#{<<"exp">> := Exp}) when is_integer(Exp) ->
    Now = os:system_time(seconds),
    case Exp =< Now of
        true  -> {error, rabbit_misc:format("Provided JWT token has expired at timestamp ~p (validated at ~p)", [Exp, Now])};
        false -> ok
    end;
validate_token_expiry(#{}) -> ok.

-spec check_token(binary()) -> {ok, map()} | {error, term()}.
check_token(Token) ->
    Settings = application:get_all_env(?APP),
    case uaa_jwt:decode_and_verify(Token) of
        {error, Reason} -> {refused, {error, Reason}};
        {true, Payload} ->
            validate_payload(post_process_payload(Payload, Settings));
        {false, _}      -> {refused, signature_invalid}
    end.

post_process_payload(Payload) when is_map(Payload) ->
    post_process_payload(Payload, []).

post_process_payload(Payload, AppEnv) when is_map(Payload) ->
    Payload0 = maps:map(fun(K, V) ->
                        case K of
                            ?AUD_JWT_FIELD   when is_binary(V) -> binary:split(V, <<" ">>, [global, trim_all]);
                            ?SCOPE_JWT_FIELD when is_binary(V) -> binary:split(V, <<" ">>, [global, trim_all]);
                            _ -> V
                        end
        end,
        Payload
    ),
    Payload1 = case does_include_complex_claim_field(Payload0) of
        true  -> post_process_payload_with_complex_claim(Payload0);
        false -> Payload0
        end,

    Payload2 = case maps:is_key(<<"authorization">>, Payload1) of
        true  -> post_process_payload_in_keycloak_format(Payload1);
        false -> Payload1
        end,

    Payload3 = case has_configured_scope_aliases(AppEnv) of
        true  -> post_process_payload_with_scope_aliases(Payload2, AppEnv);
        false -> Payload2
        end,

    Payload3.

-spec has_configured_scope_aliases(AppEnv :: app_env()) -> boolean().
has_configured_scope_aliases(AppEnv) ->
    Map = maps:from_list(AppEnv),
    maps:is_key(?SCOPE_MAPPINGS_APP_ENV_KEY, Map).


-spec post_process_payload_with_scope_aliases(Payload :: map(), AppEnv :: app_env()) -> map().
%% This is for those hopeless environments where the token structure is so out of
%% messaging team's control that even the extra scopes field is no longer an option.
%%
%% This assumes that scopes can be random values that do not follow the RabbitMQ
%% convention, or any other convention, in any way. They are just random client role IDs.
%% See rabbitmq/rabbitmq-server#4588 for details.
post_process_payload_with_scope_aliases(Payload, AppEnv) ->
    %% try JWT scope field value for alias
    Payload1 = post_process_payload_with_scope_alias_in_scope_field(Payload, AppEnv),
    %% try the configurable 'extra_scopes_source' field value for alias
    Payload2 = post_process_payload_with_scope_alias_in_extra_scopes_source(Payload1, AppEnv),
    Payload2.

-spec post_process_payload_with_scope_alias_in_scope_field(Payload :: map(),
                                                           AppEnv :: app_env()) -> map().
%% First attempt: use the value in the 'scope' field for alias
post_process_payload_with_scope_alias_in_scope_field(Payload, AppEnv) ->
    ScopeMappings = proplists:get_value(?SCOPE_MAPPINGS_APP_ENV_KEY, AppEnv, #{}),
    post_process_payload_with_scope_alias_field_named(Payload, ?SCOPE_JWT_FIELD, ScopeMappings).


-spec post_process_payload_with_scope_alias_in_extra_scopes_source(Payload :: map(),
                                                                   AppEnv :: app_env()) -> map().
%% Second attempt: use the value in the configurable 'extra scopes source' field for alias
post_process_payload_with_scope_alias_in_extra_scopes_source(Payload, AppEnv) ->
    ExtraScopesField = proplists:get_value(?COMPLEX_CLAIM_APP_ENV_KEY, AppEnv, undefined),
    case ExtraScopesField of
        %% nothing to inject
        undefined -> Payload;
        _         ->
            ScopeMappings = proplists:get_value(?SCOPE_MAPPINGS_APP_ENV_KEY, AppEnv, #{}),
            post_process_payload_with_scope_alias_field_named(Payload, ExtraScopesField, ScopeMappings)
    end.


-spec post_process_payload_with_scope_alias_field_named(Payload :: map(),
                                                        Field :: binary(),
                                                        ScopeAliasMapping :: map()) -> map().
post_process_payload_with_scope_alias_field_named(Payload, undefined, _ScopeAliasMapping) ->
    Payload;
post_process_payload_with_scope_alias_field_named(Payload, FieldName, ScopeAliasMapping) ->
      Scopes0 = maps:get(FieldName, Payload, []),
      Scopes = rabbit_data_coercion:to_list_of_binaries(Scopes0),
      %% for all scopes, look them up in the scope alias map, and if they are
      %% present, add the alias to the final scope list. Note that we also preserve
      %% the original scopes, it should not hurt.
      ExpandedScopes =
          lists:foldl(fun(ScopeListItem, Acc) ->
                        case maps:get(ScopeListItem, ScopeAliasMapping, undefined) of
                            undefined ->
                                Acc;
                            MappedList when is_list(MappedList) ->
                                Binaries = rabbit_data_coercion:to_list_of_binaries(MappedList),
                                Acc ++ Binaries;
                            Value ->
                                Binaries = rabbit_data_coercion:to_list_of_binaries(Value),
                                Acc ++ Binaries
                        end
                      end, Scopes, Scopes),
       maps:put(?SCOPE_JWT_FIELD, ExpandedScopes, Payload).


-spec does_include_complex_claim_field(Payload :: map()) -> boolean().
does_include_complex_claim_field(Payload) when is_map(Payload) ->
        maps:is_key(application:get_env(?APP, ?COMPLEX_CLAIM_APP_ENV_KEY, undefined), Payload).

-spec post_process_payload_with_complex_claim(Payload :: map()) -> map().
post_process_payload_with_complex_claim(Payload) ->
    ComplexClaim = maps:get(application:get_env(?APP, ?COMPLEX_CLAIM_APP_ENV_KEY, undefined), Payload),
    ResourceServerId = rabbit_data_coercion:to_binary(application:get_env(?APP, ?RESOURCE_SERVER_ID, <<>>)),

    AdditionalScopes =
        case ComplexClaim of
            L when is_list(L) -> L;
            M when is_map(M) ->
                case maps:get(ResourceServerId, M, undefined) of
                    undefined           -> [];
                    Ks when is_list(Ks) ->
                        [erlang:iolist_to_binary([ResourceServerId, <<".">>, K]) || K <- Ks];
                    ClaimBin when is_binary(ClaimBin) ->
                        UnprefixedClaims = binary:split(ClaimBin, <<" ">>, [global, trim_all]),
                        [erlang:iolist_to_binary([ResourceServerId, <<".">>, K]) || K <- UnprefixedClaims];
                    _ -> []
                    end;
            Bin when is_binary(Bin) ->
                binary:split(Bin, <<" ">>, [global, trim_all]);
            _ -> []
            end,

    case AdditionalScopes of
        [] -> Payload;
        _  ->
            ExistingScopes = maps:get(?SCOPE_JWT_FIELD, Payload, []),
            maps:put(?SCOPE_JWT_FIELD, AdditionalScopes ++ ExistingScopes, Payload)
        end.

-spec post_process_payload_in_keycloak_format(Payload :: map()) -> map().
%% keycloak token format: https://github.com/rabbitmq/rabbitmq-auth-backend-oauth2/issues/36
post_process_payload_in_keycloak_format(#{<<"authorization">> := Authorization} = Payload) ->
    AdditionalScopes = case maps:get(<<"permissions">>, Authorization, undefined) of
        undefined   -> [];
        Permissions -> extract_scopes_from_keycloak_permissions([], Permissions)
    end,
    ExistingScopes = maps:get(?SCOPE_JWT_FIELD, Payload),
    maps:put(?SCOPE_JWT_FIELD, AdditionalScopes ++ ExistingScopes, Payload).

extract_scopes_from_keycloak_permissions(Acc, []) ->
    Acc;
extract_scopes_from_keycloak_permissions(Acc, [H | T]) when is_map(H) ->
    Scopes = case maps:get(<<"scopes">>, H, []) of
        ScopesAsList when is_list(ScopesAsList) ->
            ScopesAsList;
        ScopesAsBinary when is_binary(ScopesAsBinary) ->
            [ScopesAsBinary]
    end,
    extract_scopes_from_keycloak_permissions(Acc ++ Scopes, T);
extract_scopes_from_keycloak_permissions(Acc, [_ | T]) ->
    extract_scopes_from_keycloak_permissions(Acc, T).

validate_payload(#{?SCOPE_JWT_FIELD := _Scope, ?AUD_JWT_FIELD := _Aud} = DecodedToken) ->
    ResourceServerEnv = application:get_env(?APP, ?RESOURCE_SERVER_ID, <<>>),
    ResourceServerId = rabbit_data_coercion:to_binary(ResourceServerEnv),
    validate_payload(DecodedToken, ResourceServerId).

validate_payload(#{?SCOPE_JWT_FIELD := Scope, ?AUD_JWT_FIELD := Aud} = DecodedToken, ResourceServerId) ->
    case check_aud(Aud, ResourceServerId) of
        ok           -> {ok, DecodedToken#{?SCOPE_JWT_FIELD => filter_scopes(Scope, ResourceServerId)}};
        {error, Err} -> {refused, {invalid_aud, Err}}
    end.

filter_scopes(Scopes, <<"">>) -> Scopes;
filter_scopes(Scopes, ResourceServerId)  ->
    PrefixPattern = <<ResourceServerId/binary, ".">>,
    matching_scopes_without_prefix(Scopes, PrefixPattern).

check_aud(_, <<>>)    -> ok;
check_aud(Aud, ResourceServerId) ->
    case Aud of
        List when is_list(List) ->
            case lists:member(ResourceServerId, Aud) of
                true  -> ok;
                false -> {error, {resource_id_not_found_in_aud, ResourceServerId, Aud}}
            end;
        _ -> {error, {badarg, {aud_is_not_a_list, Aud}}}
    end.

%%--------------------------------------------------------------------

get_scopes(#{?SCOPE_JWT_FIELD := Scope}) -> Scope.

-spec token_from_context(map()) -> binary() | undefined.
token_from_context(AuthProps) ->
    maps:get(password, AuthProps, undefined).

%% Decoded tokens look like this:
%%
%% #{<<"aud">>         => [<<"rabbitmq">>, <<"rabbit_client">>],
%%   <<"authorities">> => [<<"rabbitmq.read:*/*">>, <<"rabbitmq.write:*/*">>, <<"rabbitmq.configure:*/*">>],
%%   <<"azp">>         => <<"rabbit_client">>,
%%   <<"cid">>         => <<"rabbit_client">>,
%%   <<"client_id">>   => <<"rabbit_client">>,
%%   <<"exp">>         => 1530849387,
%%   <<"grant_type">>  => <<"client_credentials">>,
%%   <<"iat">>         => 1530806187,
%%   <<"iss">>         => <<"http://localhost:8080/uaa/oauth/token">>,
%%   <<"jti">>         => <<"df5d50a1cdcb4fa6bf32e7e03acfc74d">>,
%%   <<"rev_sig">>     => <<"2f880d5b">>,
%%   <<"scope">>       => [<<"rabbitmq.read:*/*">>, <<"rabbitmq.write:*/*">>, <<"rabbitmq.configure:*/*">>],
%%   <<"sub">>         => <<"rabbit_client">>,
%%   <<"zid">>         => <<"uaa">>}

-spec username_from(binary(), map()) -> binary() | undefined.
username_from(ClientProvidedUsername, DecodedToken) ->
    ClientId = uaa_jwt:client_id(DecodedToken, undefined),
    Sub      = uaa_jwt:sub(DecodedToken, undefined),

    rabbit_log:debug("Computing username from client's JWT token, client ID: '~s', sub: '~s'",
                     [ClientId, Sub]),

    case uaa_jwt:client_id(DecodedToken, Sub) of
        undefined ->
            case ClientProvidedUsername of
                undefined -> undefined;
                <<>>      -> undefined;
                _Other    -> ClientProvidedUsername
            end;
        Value     ->
            Value
    end.

-define(TAG_SCOPE_PREFIX, <<"tag:">>).

-spec tags_from(map()) -> list(atom()).
tags_from(DecodedToken) ->
    Scopes    = maps:get(?SCOPE_JWT_FIELD, DecodedToken, []),
    TagScopes = matching_scopes_without_prefix(Scopes, ?TAG_SCOPE_PREFIX),
    lists:usort(lists:map(fun rabbit_data_coercion:to_atom/1, TagScopes)).

matching_scopes_without_prefix(Scopes, PrefixPattern) ->
    PatternLength = byte_size(PrefixPattern),
    lists:filtermap(
        fun(ScopeEl) ->
            case binary:match(ScopeEl, PrefixPattern) of
                {0, PatternLength} ->
                    ElLength = byte_size(ScopeEl),
                    {true,
                     binary:part(ScopeEl,
                                 {PatternLength, ElLength - PatternLength})};
                _ -> false
            end
        end,
        Scopes).
