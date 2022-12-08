# OAuth 2.0 (JWT) Token Authorisation Backend for RabbitMQ

[![Build Status](https://travis-ci.org/rabbitmq/rabbitmq-auth-backend-oauth2.svg?branch=master)](https://travis-ci.org/rabbitmq/rabbitmq-auth-backend-oauth2)

This [RabbitMQ authentication/authorisation backend](https://www.rabbitmq.com/access-control.html) plugin lets applications (clients)
and users authenticate and authorize using JWT-encoded [OAuth 2.0 access tokens](https://tools.ietf.org/html/rfc6749#section-1.4).

It is not specific to but developed against [Cloud Foundry UAA](https://github.com/cloudfoundry/uaa).

An OAuth 2.0 primer is available [elsewhere on the Web](https://auth0.com/blog/oauth2-the-complete-guide/).


## Supported RabbitMQ Versions

The plugin targets and ships with RabbitMQ 3.8. Like all RabbitMQ [plugins](https://www.rabbitmq.com/plugins.html), it must be enabled before it can be used:

``` shell
rabbitmq-plugins enable rabbitmq_auth_backend_oauth2
```


## How it Works

### Authorization Workflow

This plugin does not communicate with an UAA server. It decodes an access token provided by
the client and authorises a user based on the data stored in the token.

The token can be any [JWT token](https://jwt.io/introduction/) which
contains the `scope` and `aud` fields.  The way the token was
retrieved (such as what grant type was used) is outside of the scope
of this plugin.

### Prerequisites

To use this plugin

1. UAA should be configured to produce encrypted JWT tokens containing a set of RabbitMQ permission scopes
2. All RabbitMQ nodes must be [configured to use the `rabbit_auth_backend_oauth2` backend](https://www.rabbitmq.com/access-control.html)
3. All RabbitMQ nodes must be configure with a resource service ID (`resource_server_id`) that matches the scope prefix (e.g. `rabbitmq` in `rabbitmq.read:*/*`).
4. The token **must** has a value in`aud` that match `resource_server_id` value. 

### Authorization Flow

1. Client authorize with OAuth 2.0 provider, requesting an `access_token` (using any grant type desired)
2. Token scope returned by OAuth 2.0 provider must include RabbitMQ resource scopes that follow a convention used by this plugin: `configure:%2F/foo` means "configure permissions for 'foo' in vhost '/'") (`scope` field can be changed using `extra_scopes_source` in **advanced.config** file.
3. Client passes the token as password when connecting to a RabbitMQ node. **The username field is ignored**.
4. The translated permissions are stored as part of the authenticated connection state and used the same
   way permissions from RabbitMQ's internal database would be used.


## Usage

The plugin needs a UAA signing key to be configured in order to decrypt and verify client-provided tokens.
To get the signing key from a running UAA node, use the
[token_key endpoint](https://docs.cloudfoundry.org/api/uaa/version/4.6.0/index.html#token-key-s)
or [uaac](https://github.com/cloudfoundry/cf-uaac) (the `uaac signing key` command).

The following fields are required: `kty`, `value`, `alg`, and `kid`.

Assuming UAA reports the following signing key information:

```
uaac signing key
  kty: RSA
  e: AQAB
  use: sig
  kid: a-key-ID
  alg: RS256
  value: -----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2dP+vRn+Kj+S/oGd49kq
6+CKNAduCC1raLfTH7B3qjmZYm45yDl+XmgK9CNmHXkho9qvmhdksdzDVsdeDlhK
IdcIWadhqDzdtn1hj/22iUwrhH0bd475hlKcsiZ+oy/sdgGgAzvmmTQmdMqEXqV2
B9q9KFBmo4Ahh/6+d4wM1rH9kxl0RvMAKLe+daoIHIjok8hCO4cKQQEw/ErBe4SF
2cr3wQwCfF1qVu4eAVNVfxfy/uEvG3Q7x005P3TcK+QcYgJxav3lictSi5dyWLgG
QAvkknWitpRK8KVLypEj5WKej6CF8nq30utn15FQg0JkHoqzwiCqqeen8GIPteI7
VwIDAQAB
-----END PUBLIC KEY-----
  n: ANnT_r0Z_io_kv6BnePZKuvgijQHbggta2i30x-wd6o5mWJuOcg5fl5oCvQjZh15IaPar5oXZLHcw1bHXg5YSiHXCFmnYag83bZ9YY_9tolMK4R9G3eO-YZSnLImfqMv7HYBoAM75pk0JnTKhF6ldgfavShQZqOAIYf-vneMDNax_ZMZdEbzACi3vnWqCByI6JPIQju
      HCkEBMPxKwXuEhdnK98EMAnxdalbuHgFTVX8X8v7hLxt0O8dNOT903CvkHGICcWr95YnLUouXcli4BkAL5JJ1oraUSvClS8qRI-Vino-ghfJ6t9LrZ9eRUINCZB6Ks8Igqqnnp_BiD7XiO1c
```

it will translate into the following configuration (in the [advanced RabbitMQ config format](https://www.rabbitmq.com/configure.html)):

```erlang
[
  %% ...
  %% backend configuration
  {rabbitmq_auth_backend_oauth2, [
    {resource_server_id, <<"my_rabbit_server">>},
    %% UAA signing key configuration
    {key_config, [
      {signing_keys, #{
        <<"a-key-ID">> => {pem, <<"-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2dP+vRn+Kj+S/oGd49kq
6+CKNAduCC1raLfTH7B3qjmZYm45yDl+XmgK9CNmHXkho9qvmhdksdzDVsdeDlhK
IdcIWadhqDzdtn1hj/22iUwrhH0bd475hlKcsiZ+oy/sdgGgAzvmmTQmdMqEXqV2
B9q9KFBmo4Ahh/6+d4wM1rH9kxl0RvMAKLe+daoIHIjok8hCO4cKQQEw/ErBe4SF
2cr3wQwCfF1qVu4eAVNVfxfy/uEvG3Q7x005P3TcK+QcYgJxav3lictSi5dyWLgG
QAvkknWitpRK8KVLypEj5WKej6CF8nq30utn15FQg0JkHoqzwiCqqeen8GIPteI7
VwIDAQAB
-----END PUBLIC KEY-----">>}
          }}
      ]}
    ]}
].
```

If a symmetric key is used, the configuration will look like this:

```erlang
[
  {rabbitmq_auth_backend_oauth2, [
    {resource_server_id, <<"my_rabbit_server">>},
    {key_config, [
      {signing_keys, #{
        <<"a-key-ID">> => {map, #{<<"kty">> => <<"MAC">>,
                                  <<"alg">> => <<"HS256">>,
                                  <<"value">> => <<"my_signing_key">>}}
      }}
    ]}
  ]},
].
```

The key set can also be retrieved dynamically from a URL serving a [JWK Set](https://tools.ietf.org/html/rfc7517#section-5).
In that case, the configuration will look like this:

```erlang
[
  {rabbitmq_auth_backend_oauth2, [
    {resource_server_id, <<"my_rabbit_server">>},
    {key_config, [
      {jwks_url, <<"https://my-jwt-issuer/jwks.json">>}
    ]}
  ]},
].
```

NOTE: `jwks_url` takes precedence over `signing_keys` if both are provided.

### Variables Configurable in rabbitmq.conf

| Key                                      | Documentation     
|------------------------------------------|-----------
| `auth_oauth2.resource_server_id`         | [The Resource Server ID](#resource-server-id-and-scope-prefixes)
| `auth_oauth2.additional_scopes_key`      | Configure the plugin to also look in other fields (maps to `additional_rabbitmq_scopes` in the old format).
| `auth_oauth2.default_key`                | ID of the default signing key.
| `auth_oauth2.signing_keys`               | Paths to signing key files.
| `auth_oauth2.jwks_url`                   | The URL of key server. According to the [JWT Specification](https://datatracker.ietf.org/doc/html/rfc7515#section-4.1.2) key server URL must be https.
| `auth_oauth2.https.cacertfile`           | Path to a file containing PEM-encoded CA certificates. The CA certificates are used during key server [peer verification](https://rabbitmq.com/ssl.html#peer-verification).
| `auth_oauth2.https.depth`                | The maximum number of non-self-issued intermediate certificates that may follow the peer certificate in a valid [certification path](https://rabbitmq.com/ssl.html#peer-verification-depth). Default is 10.
| `auth_oauth2.https.peer_verification`    | Should [peer verification](https://rabbitmq.com/ssl.html#peer-verification) be enabled. Available values: `verify_none`, `verify_peer`. Default is `verify_none`. It is recommended to configure `verify_peer`. Peer verification requires a certain amount of setup and is more secure.
| `auth_oauth2.https.fail_if_no_peer_cert` | Used together with `auth_oauth2.https.peer_verification = verify_peer`. When set to `true`, TLS connection will be rejected if client fails to provide a certificate. Default is `false`.
| `auth_oauth2.https.hostname_verification`| Enable wildcard-aware hostname verification for key server. Available values: `wildcard`, `none`. Default is `none`.
| `auth_oauth2.algorithms`                 | Restrict [the usable algorithms](https://github.com/potatosalad/erlang-jose#algorithm-support).

For example:

Configure with key files
```
auth_oauth2.resource_server_id = new_resource_server_id
auth_oauth2.additional_scopes_key = my_custom_scope_key
auth_oauth2.default_key = id1
auth_oauth2.signing_keys.id1 = test/config_schema_SUITE_data/certs/key.pem
auth_oauth2.signing_keys.id2 = test/config_schema_SUITE_data/certs/cert.pem
auth_oauth2.algorithms.1 = HS256
auth_oauth2.algorithms.2 = RS256
```
Configure with key server
```
auth_oauth2.resource_server_id = new_resource_server_id
auth_oauth2.jwks_url = https://my-jwt-issuer/jwks.json
auth_oauth2.https.cacertfile = test/config_schema_SUITE_data/certs/cacert.pem
auth_oauth2.https.peer_verification = verify_peer
auth_oauth2.https.depth = 5
auth_oauth2.https.fail_if_no_peer_cert = true
auth_oauth2.https.hostname_verification = wildcard
auth_oauth2.algorithms.1 = HS256
auth_oauth2.algorithms.2 = RS256
```
### Resource Server ID and Scope Prefixes

OAuth 2.0 (and thus UAA-provided) tokens use scopes to communicate what set of permissions particular
client has been granted. The scopes are free form strings.

`resource_server_id` is a prefix used for scopes in UAA to avoid scope collisions (or unintended overlap).
It is an empty string by default.

### Scope-to-Permission Translation

Scopes are translated into permission grants to RabbitMQ resources for the provided token.

The current scope format is `<permission>:<vhost_pattern>/<name_pattern>[/<routing_key_pattern>]` where

 * `<permission>` is an access permission (`configure`, `read`, or `write`)
 * `<vhost_pattern>` is a wildcard pattern for vhosts token has access to.
 * `<name_pattern>` is a wildcard pattern for resource name
 * `<routing_key_pattern>` is an optional wildcard pattern for routing key in topic authorization

Wildcard patterns are strings with optional wildcard symbols `*` that match
any sequence of characters.

Wildcard patterns match as following:

 * `*` matches any string
 * `foo*` matches any string starting with a `foo`
 * `*foo` matches any string ending with a `foo`
 * `foo*bar` matches any string starting with a `foo` and ending with a `bar`

There can be multiple wildcards in a pattern:

 * `start*middle*end`
 * `*before*after*`

**To use special characters like `*`, `%`, or `/` in a wildcard pattern,
the pattern must be [URL-encoded](https://en.wikipedia.org/wiki/Percent-encoding).**

These are the typical permissions examples:

- `read:*/*`(`read:*/*/*`) - read permissions to any resource on any vhost
- `write:*/*`(`write:*/*/*`) - write permissions to any resource on any vhost
- `read:vhost1/*`(`read:vhost1/*/*`) - read permissions to any resource on the `vhost1` vhost
- `read:vhost1/some*` - read permissions to all the resources, starting with `some` on the `vhost1` vhost
- `write:vhsot1/some*/routing*` - topic write permissions to publish to an exchange starting with `some` with a routing key starting with `routing`

See the [wildcard matching test suite](./test/wildcard_match_SUITE.erl) and [scopes test suite](./test/scope_SUITE.erl) for more examples.

Scopes should be prefixed with `resource_server_id`. For example,
if `resource_server_id` is "my_rabbit", a scope to enable read from any vhost will
be `my_rabbit.read:*/*`.

### Using a different token field for the Scope

By default the plugin will look for the `scope` key in the token, you can configure the plugin to also look in other fields using the `extra_scopes_source` setting. Values format accepted are scope as **string** or **list**


```erlang
[
  {rabbitmq_auth_backend_oauth2, [
    {resource_server_id, <<"my_rabbit_server">>},
    {extra_scopes_source, <<"my_custom_scope_key">>},
    ...
    ]}
  ]},
].
```
Token sample: 
```
{
 "exp": 1618592626,
 "iat": 1618578226,
 "aud" : ["my_id"],
 ...
 "scope_as_string": "my_id.configure:*/* my_id.read:*/* my_id.write:*/*",
 "scope_as_list": ["my_id.configure:*/*", "my_id.read:*/*", my_id.write:*/*"],
 ...
 }
```

### Using Tokens with Clients

A client must present a valid `access_token` acquired from an OAuth 2.0 provider (UAA) as the **password**
in order to authenticate with RabbitMQ.

To learn more about UAA/OAuth 2.0 clients see [UAA docs](https://github.com/cloudfoundry/uaa/blob/master/docs/UAA-APIs.rst#id73).

### Scope and Tags

Users in RabbitMQ can have [tags associated with them](https://www.rabbitmq.com/access-control.html#user-tags).
Tags are used to [control access to the management plugin](https://www.rabbitmq.com/management.html#permissions).


In the OAuth context, tags can be added as part of the scope, using a format like `<resource_server_id>.tag:<tag>`. For
example, if `resource_server_id` is "my_rabbit", a scope to grant access to the management plugin with
the `monitoring` tag will be `my_rabbit.tag:monitoring`.

## Examples

The [demo](/deps/rabbitmq_auth_backend_oauth2/demo) directory contains example configuration files which can be used to set up
a development UAA server and issue tokens, which can be used to access RabbitMQ
resources.

### UAA and RabbitMQ Config Files

To run the demo you need to have a [UAA](https://github.com/cloudfoundry/uaa) node
installed or built from source.

To make UAA use a particular config file, such as those provided in the demo directory,
export the `CLOUDFOUNDRY_CONFIG_PATH` environment variable. For example, to use symmetric keys,
see the UAA config files under the `demo/symmetric_keys` directory.

`demo/symmetric_keys/rabbit.config` contains a RabbitMQ configuration file that
sets up a matching signing key on the RabbitMQ end.

### Running UAA

To run UAA with a custom config file path, use the following from the UAA git repository:

```
CLOUDFOUNDRY_CONFIG_PATH=<path_to_plugin>/demo/symmetric_keys ./gradlew run
```

### Running RabbitMQ

```
RABBITMQ_CONFIG_FILE=<path_to_plugin>/demo/symmetric_keys/rabbitmq rabbitmq-server
## Or to run from source from the plugin directory
make run-broker RABBITMQ_CONFIG_FILE=demo/symmetric_keys/rabbitmq
```

The `rabbitmq_auth_backend_oauth2` plugin must be enabled on the RabbitMQ node.

### Asymmetric Key Example

To use an RSA (asymmetric) key, you can set `CLOUDFOUNDRY_CONFIG_PATH` to  `demo/rsa_keys`.
This directory also contains `rabbit.config` file, as well as a public key (`public_key.pem`)
which will be used for signature verification.

### UAA User and Permission Management

UAA sets scopes from client scopes and user groups. The demo uses groups to set up
a set of RabbitMQ permissions scopes.

The `demo/setup.sh` script can be used to configure a demo user and groups.
The script will also create RabbitMQ resources associated with permissions.
The script uses `uaac` and `bunny` (RabbitMQ client) and requires them to be installed.

When running the script, UAA server and RabbitMQ server should be running.
You should configure `UAA_HOST` (localhost:8080/uaa for local machine) and
`RABBITMQCTL` (a path to `rabbitmqctl` script) environment variables to run this script.

```
gem install cf-uaac
gem install bunny
RABBITMQCTL=<path_to_rabbitmqctl> demo/setup.sh
```

Please refer to `demo/setup.sh` to get more info about configuring UAA permissions.

The script will return access tokens which can be used to authenticate and authorise
in RabbitMQ. When connecting, pass the token in the **password** field. The username
field will be ignored as long as the token provides a client ID.


## License and Copyright

(c) 2016-2020 VMware, Inc. or its affiliates.

Released under the Mozilla Public License 2.0, same as RabbitMQ.
