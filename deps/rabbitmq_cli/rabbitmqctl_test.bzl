load(
    "@rules_erlang//:erlang_app_info.bzl",
    "ErlangAppInfo",
)
load(
    "@rules_erlang//:util.bzl",
    "path_join",
    "windows_path",
)
load(
    "//bazel/elixir:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(
    ":rabbitmqctl.bzl",
    "deps_dir_contents",
)

def _impl(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    deps_dir = ctx.label.name + "_deps"

    deps_dir_files = deps_dir_contents(
        ctx,
        ctx.attr.deps,
        deps_dir,
    )

    package_dir = path_join(
        ctx.label.workspace_root,
        ctx.label.package,
    )

    if not ctx.attr.is_windows:
        output = ctx.actions.declare_file(ctx.label.name)
        script = """set -euo pipefail

{maybe_install_erlang}

if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi

export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

ln -s ${{PWD}}/{package_dir}/config ${{TEST_UNDECLARED_OUTPUTS_DIR}}
ln -s ${{PWD}}/{package_dir}/lib ${{TEST_UNDECLARED_OUTPUTS_DIR}}
ln -s ${{PWD}}/{package_dir}/test ${{TEST_UNDECLARED_OUTPUTS_DIR}}
ln -s ${{PWD}}/{package_dir}/mix.exs ${{TEST_UNDECLARED_OUTPUTS_DIR}}

INITIAL_DIR=${{PWD}}
cd ${{TEST_UNDECLARED_OUTPUTS_DIR}}

export IS_BAZEL=true
export HOME=${{PWD}}
export DEPS_DIR=$TEST_SRCDIR/$TEST_WORKSPACE/{package_dir}/{deps_dir}
export MIX_ENV=test
export ERL_COMPILER_OPTIONS=deterministic
"${{ABS_ELIXIR_HOME}}"/bin/mix local.hex --force
"${{ABS_ELIXIR_HOME}}"/bin/mix local.rebar --force
"${{ABS_ELIXIR_HOME}}"/bin/mix deps.get
# "${{ABS_ELIXIR_HOME}}"/bin/mix dialyzer
if [ ! -d _build/${{MIX_ENV}}/lib/rabbit_common ]; then
    cp -r ${{DEPS_DIR}}/* _build/${{MIX_ENV}}/lib
fi
"${{ABS_ELIXIR_HOME}}"/bin/mix deps.compile
"${{ABS_ELIXIR_HOME}}"/bin/mix compile

# due to https://github.com/elixir-lang/elixir/issues/7699 we
# "run" the tests, but skip them all, in order to trigger
# compilation of all *_test.exs files before we actually run them
"${{ABS_ELIXIR_HOME}}"/bin/mix test --exclude test

export TEST_TMPDIR=${{TEST_UNDECLARED_OUTPUTS_DIR}}

# we need a running broker with certain plugins for this to pass 
trap 'catch $?' EXIT
catch() {{
    pid=$(cat ${{TEST_TMPDIR}}/*/*.pid)
    kill -TERM "${{pid}}"
}}
cd ${{INITIAL_DIR}}
./{rabbitmq_run_cmd} start-background-broker
cd ${{TEST_UNDECLARED_OUTPUTS_DIR}}

# The test cases will need to be able to load code from the deps
# directly, so we set ERL_LIBS
export ERL_LIBS=$DEPS_DIR

# run the actual tests
set +u
set -x
"${{ABS_ELIXIR_HOME}}"/bin/mix test --trace --max-failures 1 ${{TEST_FILE}}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            elixir_home = elixir_home,
            package_dir = package_dir,
            deps_dir = deps_dir,
            rabbitmq_run_cmd = ctx.attr.rabbitmq_run[DefaultInfo].files_to_run.executable.short_path,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """@echo off
echo Erlang Version: {erlang_version}

:: set LANG="en_US.UTF-8"
:: set LC_ALL="en_US.UTF-8"

set PATH="{elixir_home}\\bin";"{erlang_home}\\bin";%PATH%

set OUTPUTS_DIR=%TEST_UNDECLARED_OUTPUTS_DIR:/=\\%

:: robocopy exits non-zero when files are copied successfully
:: https://social.msdn.microsoft.com/Forums/en-US/d599833c-dcea-46f5-85e9-b1f028a0fefe/robocopy-exits-with-error-code-1?forum=tfsbuild
robocopy {package_dir}\\config %OUTPUTS_DIR%\\config /E /NFL /NDL /NJH /NJS /nc /ns /np
robocopy {package_dir}\\lib %OUTPUTS_DIR%\\lib /E /NFL /NDL /NJH /NJS /nc /ns /np
robocopy {package_dir}\\test %OUTPUTS_DIR%\\test /E /NFL /NDL /NJH /NJS /nc /ns /np
copy {package_dir}\\mix.exs %OUTPUTS_DIR%\\mix.exs || goto :error

cd %OUTPUTS_DIR% || goto :error

set DEPS_DIR=%TEST_SRCDIR%/%TEST_WORKSPACE%/{package_dir}/{deps_dir}
set DEPS_DIR=%DEPS_DIR:/=\\%
set ERL_COMPILER_OPTIONS=deterministic
set MIX_ENV=test mix dialyzer
echo y | "{elixir_home}\\bin\\mix" local.hex --force || goto :error
echo y | "{elixir_home}\\bin\\mix" local.rebar --force || goto :error
echo y | "{elixir_home}\\bin\\mix" make_all || goto :error

REM need to start the background broker here
set TEST_TEMPDIR=%OUTPUTS_DIR%

set ERL_LIBS=%DEPS_DIR%

"{elixir_home}\\bin\\mix" test --trace --max-failures 1 || goto :error
goto :EOF
:error
exit /b 1
""".format(
            erlang_home = windows_path(erlang_home),
            elixir_home = windows_path(elixir_home),
            package_dir = windows_path(ctx.label.package),
            deps_dir = deps_dir,
            rabbitmq_run_cmd = ctx.attr.rabbitmq_run[DefaultInfo].files_to_run.executable.short_path,
        )

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = ctx.runfiles(
        files = ctx.files.srcs + ctx.files.data,
        transitive_files = depset(deps_dir_files),
    ).merge_all([
        erlang_runfiles,
        elixir_runfiles,
        ctx.attr.rabbitmq_run[DefaultInfo].default_runfiles,
    ])

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

rabbitmqctl_private_test = rule(
    implementation = _impl,
    attrs = {
        "is_windows": attr.bool(mandatory = True),
        "srcs": attr.label_list(allow_files = [".ex", ".exs"]),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "rabbitmq_run": attr.label(
            executable = True,
            cfg = "target",
        ),
    },
    toolchains = [
        "//bazel/elixir:toolchain_type",
    ],
    test = True,
)

def rabbitmqctl_test(**kwargs):
    rabbitmqctl_private_test(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
