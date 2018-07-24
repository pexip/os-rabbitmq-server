IGNORE_DEPS += edown eper eunit_formatters meck node_package rebar_lock_deps_plugin rebar_vsn_plugin reltool_util
C_SRC_DIR = /path/do/not/exist
C_SRC_TYPE = rebar
DRV_CFLAGS = -fPIC
export DRV_CFLAGS
ERLANG_ARCH = 64
export ERLANG_ARCH
ERLC_OPTS = +debug_info
export ERLC_OPTS
ERLC_OPTS += -Dold_hash=1

DEPS += mochiweb
dep_mochiweb = git git://github.com/rabbitmq/mochiweb 845428379ed8b58eadc49aba26838d86ea809663
COMPILE_FIRST +=


rebar_dep: preprocess pre-deps deps pre-app app

preprocess::

pre-deps::

pre-app::

include ../../erlang.mk