"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    arguments = ctx.actions.args()
    arguments.add_all([
        "--into",
        install_dir.path,
        "--wheel",
        archive.path,
        "--python-version-major",
        py_toolchain.interpreter_version_info.major,
        "--python-version-minor",
        py_toolchain.interpreter_version_info.minor,
    ])

    # Need to read the toolchain config from the unpack target so we can grab
    # its bin and run it. Note that we have to do this dance in order to get the
    # unpack toolchain in the "exec" rather than target config. This allows us
    # to use unpack in crossbuild scenarios.
    unpack = ctx.attr._unpack[platform_common.ToolchainInfo].bin.bin
    ctx.actions.run(
        executable = unpack,
        arguments = [arguments],
        inputs = [archive],
        outputs = [
            install_dir,
        ],
    )

    return [
        DefaultInfo(
            files = depset([
                install_dir,
            ]),
            runfiles = ctx.runfiles(files = [
                install_dir,
            ]),
        ),
        PyInfo(
            transitive_sources = depset([
                install_dir,
            ]),
            imports = depset([
                ctx.label.repo_name + "/install/lib/python{}.{}/site-packages".format(
                    py_toolchain.interpreter_version_info.major,
                    py_toolchain.interpreter_version_info.minor,
                ),
            ]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
    ]

whl_install = rule(
    implementation = _whl_install,
    doc = """
Private implementation detail of aspect_rules_py//uv.

Installing wheels as a Bazel build action, rather than a repo step.

We implement wheel installation without an interpreter (or even uv) by using our
unpack tool, which uses a subset of UV's machinery. Critically, this allows us
to bypass some of the platform checks that UV does to enable crossbuilds, and is
lighter weight since the toolchain's files aren't inputs.
""",
    attrs = {
        "src": attr.label(doc = "The wheel to install, or a tree artifact containing exactly one wheel at its root."),
        "_unpack": attr.label(
            default = "//py/private/toolchain:resolved_unpack_toolchain",
            cfg = "exec",
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        PyInfo,
    ],
)

def _whl_dist_info(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    dist_info_dir = ctx.actions.declare_directory("dist_info")
    entry_points_txt = ctx.actions.declare_file("entry_points.txt")

    args = ctx.actions.args()
    args.add_all([
        "--wheel",
        archive.path,
        "--dist-info-dir",
        dist_info_dir.path,
        "--entry-points-out",
        entry_points_txt.path,
    ])

    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = [archive],
        outputs = [
            dist_info_dir,
            entry_points_txt,
        ],
        mnemonic = "WhlDistInfo",
        progress_message = "Extracting wheel dist-info %{label}",
    )

    return [DefaultInfo(files = depset([
        dist_info_dir,
        entry_points_txt,
    ]))]

whl_dist_info = rule(
    implementation = _whl_dist_info,
    doc = """
Private implementation detail of aspect_rules_py//uv.

Extracts dist-info metadata from the selected wheel so consumers such as
rules_python's py_console_script_binary can discover entry_points.txt.
""",
    attrs = {
        "src": attr.label(doc = "The wheel to inspect."),
        "_tool": attr.label(
            default = "//uv/private/whl_install:extract_dist_info",
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [
        DefaultInfo,
    ],
)
