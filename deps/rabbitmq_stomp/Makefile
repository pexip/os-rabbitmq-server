PROJECT = rabbitmq_stomp
PROJECT_DESCRIPTION = RabbitMQ STOMP plugin
PROJECT_MOD = rabbit_stomp

define PROJECT_ENV
[
	    {default_user,
	     [{login, <<"guest">>},
	      {passcode, <<"guest">>}]},
	    {default_vhost, <<"/">>},
	    {ssl_cert_login, false},
	    {implicit_connect, false},
	    {tcp_listeners, [61613]},
	    {num_tcp_acceptors, 10},
	    {ssl_listeners, []},
	    {num_ssl_acceptors, 1},
	    {tcp_listen_options, [{backlog,   128},
	                          {nodelay,   true}]},
	    %% see rabbitmq/rabbitmq-stomp#39
	    {trailing_lf, true},
	    %% see rabbitmq/rabbitmq-stomp#57
	    {hide_server_info, false},
	    {proxy_protocol, false}
	  ]
endef

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

DEPS = ranch rabbit_common rabbit amqp_client ranch_proxy_protocol
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

ELIXIR_LIB_DIR = $(shell elixir -e 'IO.puts(:code.lib_dir(:elixir))')
 ifeq ($(ERL_LIBS),)
     ERL_LIBS = $(ELIXIR_LIB_DIR)
 else
     ERL_LIBS := $(ERL_LIBS):$(ELIXIR_LIB_DIR)
 endif
# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk
