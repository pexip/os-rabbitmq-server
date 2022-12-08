load("@rules_pkg//:pkg.bzl", "pkg_tar")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load("@rules_erlang//:ct.bzl", "additional_file_dest_relative_path")
load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)
load("@rules_erlang//:source_tree.bzl", "source_tree")
load(
    ":rabbitmq_home.bzl",
    "RABBITMQ_HOME_ATTRS",
    "RabbitmqHomeInfo",
    "flatten",
    "link_escript",
)
load(
    ":rabbitmq.bzl",
    "APP_VERSION",
)

def _collect_licenses_impl(ctx):
    srcs = ctx.files.srcs + flatten([
        d[ErlangAppInfo].license_files
        for d in flat_deps(ctx.attr.deps)
    ])

    outs = {}
    for src in srcs:
        name = src.basename
        if name not in outs:
            dest = ctx.actions.declare_file(name)
            ctx.actions.run(
                inputs = [src],
                outputs = [dest],
                executable = "cp",
                arguments = [
                    src.path,
                    dest.path,
                ],
            )
            outs[name] = dest

    return [
        DefaultInfo(
            files = depset(sorted(outs.values())),
        ),
    ]

collect_licenses = rule(
    implementation = _collect_licenses_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
    },
)

def _copy_script(ctx, script):
    dest = ctx.actions.declare_file(path_join(ctx.label.name, "sbin", script.basename))
    ctx.actions.expand_template(
        template = script,
        output = dest,
        substitutions = {
            "SYS_PREFIX=": "SYS_PREFIX=${RABBITMQ_HOME}",
        },
    )
    return dest

def _scripts_and_escripts_private_impl(ctx):
    plugins = flat_deps(ctx.attr.plugins)

    scripts = [_copy_script(ctx, script) for script in ctx.files._scripts]

    rabbitmq_ctl_copies = [
        "rabbitmq-diagnostics",
        "rabbitmq-plugins",
        "rabbitmq-queues",
        "rabbitmq-streams",
        "rabbitmq-tanzu",
        "rabbitmq-upgrade",
        "rabbitmqctl",
    ]
    escripts = [link_escript(ctx, escript) for escript in rabbitmq_ctl_copies]

    rabbitmqctl = None
    for script in scripts:
        if script.basename == "rabbitmqctl":
            rabbitmqctl = script
    if rabbitmqctl == None:
        fail("could not find rabbitmqct among", scripts)

    return [
        RabbitmqHomeInfo(
            rabbitmqctl = rabbitmqctl,
        ),
        DefaultInfo(
            files = depset(scripts + escripts),
        ),
    ]

scripts_and_escripts_private = rule(
    implementation = _scripts_and_escripts_private_impl,
    attrs = RABBITMQ_HOME_ATTRS,
)

def scripts_and_escripts(**kwargs):
    scripts_and_escripts_private(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )

def _extract_version(p):
    return "erl -eval '{ok, [{application, _, AppInfo}]} = file:consult(\"" + p + "\"), Version = proplists:get_value(vsn, AppInfo), io:fwrite(Version), halt().' -noshell"

def _app_file(plugin_lib_info):
    for f in plugin_lib_info.beam:
        if f.basename.endswith(".app"):
            return f
    fail(".app file not found in {}".format(plugin_lib_info))

def _versioned_plugins_dir_impl(ctx):
    plugins = flat_deps(ctx.attr.plugins)

    plugins_dir = ctx.actions.declare_directory(path_join(ctx.label.name, "plugins"))

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    inputs = runfiles.files.to_list()

    commands = [
        "set -euo pipefail",
        "",
        maybe_install_erlang(ctx),
    ]

    for plugin in plugins:
        lib_info = plugin[ErlangAppInfo]
        app_file = _app_file(lib_info)
        extract_version = _extract_version(app_file.path)
        commands.append("PLUGIN_VERSION=$({erlang_home}/bin/{extract_version})".format(erlang_home = erlang_home, extract_version = extract_version))

        commands.append(
            "mkdir -p {plugins_dir}/{lib_name}-$PLUGIN_VERSION/include".format(
                plugins_dir = plugins_dir.path,
                lib_name = lib_info.app_name,
            ),
        )
        for f in lib_info.include:
            commands.append(
                "cp {src} {plugins_dir}/{lib_name}-$PLUGIN_VERSION/include/{dest}".format(
                    src = f.path,
                    plugins_dir = plugins_dir.path,
                    lib_name = lib_info.app_name,
                    dest = f.basename,
                ),
            )
        inputs.extend(lib_info.include)

        commands.append(
            "mkdir -p {plugins_dir}/{lib_name}-$PLUGIN_VERSION/ebin".format(
                plugins_dir = plugins_dir.path,
                lib_name = lib_info.app_name,
            ),
        )
        for f in lib_info.beam:
            if f.is_directory:
                if f.basename != "ebin":
                    fail("{} contains a directory in 'beam' that is not an ebin dir".format(lib_info.app_name))
                commands.append(
                    "cp -R {src} {plugins_dir}/{lib_name}-$PLUGIN_VERSION".format(
                        src = f.path,
                        plugins_dir = plugins_dir.path,
                        lib_name = lib_info.app_name,
                    ),
                )
            else:
                commands.append(
                    "cp {src} {plugins_dir}/{lib_name}-$PLUGIN_VERSION/ebin/{dest}".format(
                        src = f.path,
                        plugins_dir = plugins_dir.path,
                        lib_name = lib_info.app_name,
                        dest = f.basename,
                    ),
                )
        inputs.extend(lib_info.beam)

        for f in lib_info.priv:
            p = additional_file_dest_relative_path(plugin.label, f)
            commands.append(
                "mkdir -p $(dirname {plugins_dir}/{lib_name}-$PLUGIN_VERSION/{dest}) && cp {src} {plugins_dir}/{lib_name}-$PLUGIN_VERSION/{dest}".format(
                    src = f.path,
                    plugins_dir = plugins_dir.path,
                    lib_name = lib_info.app_name,
                    dest = p,
                ),
            )
        inputs.extend(lib_info.priv)

        commands.append("")

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [plugins_dir],
        command = "\n".join(commands),
    )

    return [
        DefaultInfo(
            files = depset([plugins_dir]),
        ),
    ]

versioned_plugins_dir_private = rule(
    implementation = _versioned_plugins_dir_impl,
    attrs = RABBITMQ_HOME_ATTRS,
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)

def versioned_plugins_dir(**kwargs):
    versioned_plugins_dir_private(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )

def package_generic_unix(
        plugins = None,
        rabbitmq_workspace = "@",
        package_dir = "rabbitmq_server-{}".format(APP_VERSION)):
    collect_licenses(
        name = "licenses",
        srcs = [
            rabbitmq_workspace + "//:root-licenses",
        ],
        deps = plugins,
    )

    pkg_tar(
        name = "license-files-tar",
        srcs = [
            ":licenses",
            rabbitmq_workspace + "//deps/rabbit:INSTALL",
        ],
        visibility = ["//visibility:public"],
    )

    scripts_and_escripts(
        name = "scripts-and-escripts",
    )

    versioned_plugins_dir(
        name = "plugins-dir",
        plugins = plugins,
    )

    pkg_tar(
        name = "plugins-tar",
        srcs = [
            ":plugins-dir",
        ],
        package_dir = "plugins",
    )

    pkg_tar(
        name = "package-generic-unix",
        extension = "tar.xz",
        srcs = [
            ":scripts-and-escripts",
        ],
        package_dir = package_dir,
        strip_prefix = "scripts-and-escripts",
        visibility = ["//visibility:public"],
        deps = [
            ":plugins-tar",
            ":license-files-tar",
            rabbitmq_workspace + "//:release-notes-tar",
            rabbitmq_workspace + "//:scripts-tar",
            rabbitmq_workspace + "//deps/rabbit:manpages-dir",
        ],
    )

def source_archive(
        plugins = None,
        rabbitmq_workspace = "@"):
    source_tree(
        name = "source-tree",
        deps = plugins + [
            rabbitmq_workspace + "//deps/rabbitmq_cli:rabbitmqctl",
        ],
    )

    pkg_tar(
        name = "deps-archive",
        srcs = [
            ":source-tree",
        ],
        package_dir = "deps",
        strip_prefix = "source-tree",
    )

    pkg_tar(
        name = "cli-deps-archive",
        deps = [
            rabbitmq_workspace + "//deps/rabbitmq_cli:fetched_srcs",
        ],
        package_dir = "deps/rabbitmq_cli",
    )

    pkg_tar(
        name = "source_archive",
        extension = "tar.gz",
        srcs = [
            rabbitmq_workspace + "//:root-licenses",
        ],
        deps = [
            ":deps-archive",
            ":cli-deps-archive",
        ],
        visibility = ["//visibility:public"],
    )
