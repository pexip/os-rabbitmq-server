%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2018-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_maintenance).

-include("rabbit.hrl").

-export([
    is_enabled/0,
    drain/0,
    revive/0,
    mark_as_being_drained/0,
    unmark_as_being_drained/0,
    is_being_drained_local_read/1,
    is_being_drained_consistent_read/1,
    status_local_read/1,
    status_consistent_read/1,
    filter_out_drained_nodes_local_read/1,
    filter_out_drained_nodes_consistent_read/1,
    suspend_all_client_listeners/0,
    resume_all_client_listeners/0,
    close_all_client_connections/0,
    primary_replica_transfer_candidate_nodes/0,
    random_primary_replica_transfer_candidate_node/1,
    transfer_leadership_of_quorum_queues/1,
    transfer_leadership_of_classic_mirrored_queues/1,
    status_table_name/0,
    status_table_definition/0
]).

-define(TABLE, rabbit_node_maintenance_states).
-define(FEATURE_FLAG, maintenance_mode_status).
-define(DEFAULT_STATUS,  regular).
-define(DRAINING_STATUS, draining).

-type maintenance_status() :: ?DEFAULT_STATUS | ?DRAINING_STATUS.

-export_type([
    maintenance_status/0
]).

%%
%% API
%%

-spec status_table_name() -> mnesia:table().
status_table_name() ->
    ?TABLE.

-spec status_table_definition() -> list().
status_table_definition() ->
    maps:to_list(#{
        record_name => node_maintenance_state,
        attributes  => record_info(fields, node_maintenance_state)
    }).

-spec is_enabled() -> boolean().
is_enabled() ->
    rabbit_feature_flags:is_enabled(?FEATURE_FLAG).

-spec drain() -> ok.
drain() ->
    case is_enabled() of
        true  -> do_drain();
        false -> rabbit_log:warning("Feature flag `~s` is not enabled, draining is a no-op", [?FEATURE_FLAG])
    end.

-spec do_drain() -> ok.
do_drain() ->
    rabbit_log:alert("This node is being put into maintenance (drain) mode"),
    mark_as_being_drained(),
    rabbit_log:info("Marked this node as undergoing maintenance"),
    suspend_all_client_listeners(),
    rabbit_log:alert("Suspended all listeners and will no longer accept client connections"),
    {ok, NConnections} = close_all_client_connections(),
    %% allow plugins to react e.g. by closing their protocol connections
    rabbit_event:notify(maintenance_connections_closed, #{
        reason => <<"node is being put into maintenance">>
    }),
    rabbit_log:alert("Closed ~b local client connections", [NConnections]),

    TransferCandidates = primary_replica_transfer_candidate_nodes(),
    ReadableCandidates = readable_candidate_list(TransferCandidates),
    rabbit_log:info("Node will transfer primary replicas of its queues to ~b peers: ~s",
                    [length(TransferCandidates), ReadableCandidates]),
    transfer_leadership_of_classic_mirrored_queues(TransferCandidates),
    transfer_leadership_of_quorum_queues(TransferCandidates),

    %% allow plugins to react
    rabbit_event:notify(maintenance_draining, #{
        reason => <<"node is being put into maintenance">>
    }),
    rabbit_log:alert("Node is ready to be shut down for maintenance or upgrade"),

    ok.

-spec revive() -> ok.
revive() ->
    case is_enabled() of
        true  -> do_revive();
        false -> rabbit_log:warning("Feature flag `~s` is not enabled, reviving is a no-op", [?FEATURE_FLAG])
    end.

-spec do_revive() -> ok.
do_revive() ->
    rabbit_log:alert("This node is being revived from maintenance (drain) mode"),
    revive_local_quorum_queue_replicas(),
    rabbit_log:alert("Resumed all listeners and will accept client connections again"),
    resume_all_client_listeners(),
    rabbit_log:alert("Resumed all listeners and will accept client connections again"),
    unmark_as_being_drained(),
    rabbit_log:info("Marked this node as back from maintenance and ready to serve clients"),

    %% allow plugins to react
    rabbit_event:notify(maintenance_revived, #{}),

    ok.
 
-spec mark_as_being_drained() -> boolean().
mark_as_being_drained() ->
    rabbit_log:debug("Marking the node as undergoing maintenance"),
    set_maintenance_status_status(?DRAINING_STATUS).
 
-spec unmark_as_being_drained() -> boolean().
unmark_as_being_drained() ->
    rabbit_log:debug("Unmarking the node as undergoing maintenance"),
    set_maintenance_status_status(?DEFAULT_STATUS).

set_maintenance_status_status(Status) ->
    Res = mnesia:transaction(fun () ->
        case mnesia:wread({?TABLE, node()}) of
           [] ->
                Row = #node_maintenance_state{
                        node   = node(),
                        status = Status
                     },
                mnesia:write(?TABLE, Row, write);
            [Row0] ->
                Row = Row0#node_maintenance_state{
                        node   = node(),
                        status = Status
                      },
                mnesia:write(?TABLE, Row, write)
        end
    end),
    case Res of
        {atomic, ok} -> true;
        _            -> false
    end.
 
 
-spec is_being_drained_local_read(node()) -> boolean().
is_being_drained_local_read(Node) ->
    Status = status_local_read(Node),
    Status =:= ?DRAINING_STATUS.

-spec is_being_drained_consistent_read(node()) -> boolean().
is_being_drained_consistent_read(Node) ->
    Status = status_consistent_read(Node),
    Status =:= ?DRAINING_STATUS.

-spec status_local_read(node()) -> maintenance_status().
status_local_read(Node) ->
    case catch mnesia:dirty_read(?TABLE, Node) of
        []  -> ?DEFAULT_STATUS;
        [#node_maintenance_state{node = Node, status = Status}] ->
            Status;
        _   -> ?DEFAULT_STATUS
    end.
 
-spec status_consistent_read(node()) -> maintenance_status().
status_consistent_read(Node) ->
    case mnesia:transaction(fun() -> mnesia:read(?TABLE, Node) end) of
        {atomic, []} -> ?DEFAULT_STATUS;
        {atomic, [#node_maintenance_state{node = Node, status = Status}]} ->
            Status;
        {atomic, _}  -> ?DEFAULT_STATUS;
        {aborted, _Reason} -> ?DEFAULT_STATUS
    end.
 
 -spec filter_out_drained_nodes_local_read([node()]) -> [node()].
filter_out_drained_nodes_local_read(Nodes) ->
    lists:filter(fun(N) -> not is_being_drained_local_read(N) end, Nodes).
 
-spec filter_out_drained_nodes_consistent_read([node()]) -> [node()].
filter_out_drained_nodes_consistent_read(Nodes) ->
    lists:filter(fun(N) -> not is_being_drained_consistent_read(N) end, Nodes).
 
-spec suspend_all_client_listeners() -> rabbit_types:ok_or_error(any()).
 %% Pauses all listeners on the current node except for
 %% Erlang distribution (clustering and CLI tools).
 %% A respausedumed listener will not accept any new client connections
 %% but previously established connections won't be interrupted.
suspend_all_client_listeners() ->
    Listeners = rabbit_networking:node_client_listeners(node()),
    rabbit_log:info("Asked to suspend ~b client connection listeners. "
                    "No new client connections will be accepted until these listeners are resumed!", [length(Listeners)]),
    Results = lists:foldl(local_listener_fold_fun(fun ranch:suspend_listener/1), [], Listeners),
    lists:foldl(fun ok_or_first_error/2, ok, Results).

 -spec resume_all_client_listeners() -> rabbit_types:ok_or_error(any()).
 %% Resumes all listeners on the current node except for
 %% Erlang distribution (clustering and CLI tools).
 %% A resumed listener will accept new client connections.
resume_all_client_listeners() ->
    Listeners = rabbit_networking:node_client_listeners(node()),
    rabbit_log:info("Asked to resume ~b client connection listeners. "
                    "New client connections will be accepted from now on", [length(Listeners)]),
    Results = lists:foldl(local_listener_fold_fun(fun ranch:resume_listener/1), [], Listeners),
    lists:foldl(fun ok_or_first_error/2, ok, Results).

 -spec close_all_client_connections() -> {'ok', non_neg_integer()}.
close_all_client_connections() ->
    Pids = rabbit_networking:local_connections(),
    rabbit_networking:close_connections(Pids, "Node was put into maintenance mode"),
    {ok, length(Pids)}.

-spec transfer_leadership_of_quorum_queues([node()]) -> ok.
transfer_leadership_of_quorum_queues([]) ->
    rabbit_log:warning("Skipping leadership transfer of quorum queues: no candidate "
                       "(online, not under maintenance) nodes to transfer to!");
transfer_leadership_of_quorum_queues(_TransferCandidates) ->
    %% we only transfer leadership for QQs that have local leaders
    Queues = rabbit_amqqueue:list_local_leaders(),
    rabbit_log:info("Will transfer leadership of ~b quorum queues with current leader on this node",
                    [length(Queues)]),
    [begin
        Name = amqqueue:get_name(Q),
        rabbit_log:debug("Will trigger a leader election for local quorum queue ~s",
                         [rabbit_misc:rs(Name)]),
        %% we trigger an election and exclude this node from the list of candidates
        %% by simply shutting its local QQ replica (Ra server)
        RaLeader = amqqueue:get_pid(Q),
        rabbit_log:debug("Will stop Ra server ~p", [RaLeader]),
        case ra:stop_server(RaLeader) of
            ok     ->
                rabbit_log:debug("Successfully stopped Ra server ~p", [RaLeader]);
            {error, nodedown} ->
                rabbit_log:error("Failed to stop Ra server ~p: target node was reported as down")
        end
     end || Q <- Queues],
    rabbit_log:info("Leadership transfer for quorum queues hosted on this node has been initiated").

-spec transfer_leadership_of_classic_mirrored_queues([node()]) -> ok.
 transfer_leadership_of_classic_mirrored_queues([]) ->
    rabbit_log:warning("Skipping leadership transfer of classic mirrored queues: no candidate "
                       "(online, not under maintenance) nodes to transfer to!");
transfer_leadership_of_classic_mirrored_queues(TransferCandidates) ->
    Queues = rabbit_amqqueue:list_local_mirrored_classic_queues(),
    ReadableCandidates = readable_candidate_list(TransferCandidates),
    rabbit_log:info("Will transfer leadership of ~b classic mirrored queues hosted on this node to these peer nodes: ~s",
                    [length(Queues), ReadableCandidates]),
    
    [begin
         Name = amqqueue:get_name(Q),
         case random_primary_replica_transfer_candidate_node(TransferCandidates) of
             {ok, Pick} ->
                 rabbit_log:debug("Will transfer leadership of local queue ~s to node ~s",
                          [rabbit_misc:rs(Name), Pick]),
                 case rabbit_mirror_queue_misc:transfer_leadership(Q, Pick) of
                     {migrated, _} ->
                         rabbit_log:debug("Successfully transferred leadership of queue ~s to node ~s",
                                          [rabbit_misc:rs(Name), Pick]);
                     Other ->
                         rabbit_log:warning("Could not transfer leadership of queue ~s to node ~s: ~p",
                                            [rabbit_misc:rs(Name), Pick, Other])
                 end;
             undefined ->
                 rabbit_log:warning("Could not transfer leadership of queue ~s: no suitable candidates?",
                                    [Name])
         end
     end || Q <- Queues],
    rabbit_log:info("Leadership transfer for local classic mirrored queues is complete").

 -spec primary_replica_transfer_candidate_nodes() -> [node()].
primary_replica_transfer_candidate_nodes() ->
    filter_out_drained_nodes_consistent_read(rabbit_nodes:all_running() -- [node()]).

-spec random_primary_replica_transfer_candidate_node([node()]) -> {ok, node()} | undefined.
random_primary_replica_transfer_candidate_node([]) ->
    undefined;
random_primary_replica_transfer_candidate_node(Candidates) ->
    Nth = erlang:phash2(erlang:monotonic_time(), length(Candidates)),
    Candidate = lists:nth(Nth + 1, Candidates),
    {ok, Candidate}.

revive_local_quorum_queue_replicas() ->
    Queues = rabbit_amqqueue:list_local_followers(),
    [begin
        Name = amqqueue:get_name(Q),
        rabbit_log:debug("Will trigger a leader election for local quorum queue ~s",
                         [rabbit_misc:rs(Name)]),
        %% start local QQ replica (Ra server) of this queue
        {Prefix, _Node} = amqqueue:get_pid(Q),
        RaServer = {Prefix, node()},
        rabbit_log:debug("Will start Ra server ~p", [RaServer]),
        case ra:restart_server(RaServer) of
            ok     ->
                rabbit_log:debug("Successfully restarted Ra server ~p", [RaServer]);
            {error, {already_started, _Pid}} ->
                rabbit_log:debug("Ra server ~p is already running", [RaServer]);
            {error, nodedown} ->
                rabbit_log:error("Failed to restart Ra server ~p: target node was reported as down")
        end
     end || Q <- Queues],
    rabbit_log:info("Restart of local quorum queue replicas is complete").
 
%%
%% Implementation
%%

local_listener_fold_fun(Fun) ->
    fun(#listener{node = Node, ip_address = Addr, port = Port}, Acc) when Node =:= node() ->
            RanchRef = rabbit_networking:ranch_ref(Addr, Port),
            [Fun(RanchRef) | Acc];
        (_, Acc) ->
            Acc
    end.
 
ok_or_first_error(ok, Acc) ->
    Acc;
ok_or_first_error({error, _} = Err, _Acc) ->
    Err.
 
readable_candidate_list(Nodes) ->
    string:join(lists:map(fun rabbit_data_coercion:to_list/1, Nodes), ", ").
