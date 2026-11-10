"""Generate the real build-dependency graph for the B -> A -> C fixture."""

# Use the production sdist inspector's PBS interpreter, not a host Python.
# buildifier: disable=bzl-visibility
load("//py/private/interpreter:resolve.bzl", "resolve_host_interpreter_label")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/uv_project:repository.bzl", "declare_project")

def _source_impl(repository_ctx):
    repository_ctx.watch(repository_ctx.attr.interpreter)
    for src in repository_ctx.attr.srcs:
        repository_ctx.watch(src)
    result = repository_ctx.execute(
        [
            str(repository_ctx.path(repository_ctx.attr.interpreter)),
            "-I",
            "-c",
            """\
import gzip
import io
from pathlib import Path
import sys
import tarfile

with open(sys.argv[1], "wb") as output:
    with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for filename in sorted(sys.argv[2:]):
                source = Path(filename)
                content = source.read_bytes()
                member = tarfile.TarInfo("self_exclusion_a-0.0.1/" + source.name)
                member.size = len(content)
                member.mode = 0o644
                member.mtime = 0
                archive.addfile(member, io.BytesIO(content))
""",
            str(repository_ctx.path("source.tar.gz")),
        ] + [str(repository_ctx.path(src)) for src in repository_ctx.attr.srcs],
        timeout = 30,
    )
    if result.return_code:
        fail("Could not create the self-exclusion fixture archive: " + result.stderr)
    repository_ctx.file("BUILD.bazel", 'exports_files(["source.tar.gz"], visibility = ["//visibility:public"])')
    return repository_ctx.repo_metadata(reproducible = True)

_source = repository_rule(
    implementation = _source_impl,
    attrs = {
        "interpreter": attr.label(mandatory = True),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
    },
)

def _graph_layout_impl(repository_ctx):
    # Inspect repository output before analysis so the private BUILD files
    # need not be exported just for this test.
    all_names = ["a", "b", "c", "unused"]
    for label, files in [
        (repository_ctx.attr.project_build, [
            ("packages.bzl", all_names),
            ("components.bzl", all_names),
        ]),
        (repository_ctx.attr.source_build, [
            ("private/build_deps/BUILD.bazel", ["b"]),
            ("private/build_deps/sccs/BUILD.bazel", ["a", "b", "c"]),
        ]),
    ]:
        root = repository_ctx.path(label).dirname
        build_deps = root.get_child("private/build_deps")
        for path in [
            root.get_child("build_deps_without_self"),
            build_deps.get_child("without"),
            build_deps.get_child("without_self"),
        ]:
            repository_ctx.watch(path)
            if path.exists:
                fail("Unexpected per-consumer graph output in " + str(path))
        for filename, expected in files:
            path = root.get_child(filename)
            repository_ctx.watch(path)
            content = "\n".join([line.lstrip() for line in repository_ctx.read(path).splitlines()])
            names = sorted([
                declaration.split('"')[1]
                for declaration in content.split("py_library(\nname = ")[1:]
            ])
            if names != expected:
                fail("Expected libraries {} in {}, got {}".format(expected, path, names))

    repository_ctx.file("verified.txt", "Shared and source build-dependency graph layouts verified.\n")
    repository_ctx.file("BUILD.bazel", 'exports_files(["verified.txt"], visibility = ["//visibility:public"])')
    return repository_ctx.repo_metadata(reproducible = True)

_graph_layout = repository_rule(
    implementation = _graph_layout_impl,
    attrs = {
        "project_build": attr.label(mandatory = True),
        "source_build": attr.label(mandatory = True),
    },
)

def _self_exclusion_fixture_impl(module_ctx):
    interpreter = resolve_host_interpreter_label(module_ctx)
    if interpreter == None:
        fail("The self-exclusion fixture requires a supported host PBS interpreter.")
    _source(
        name = "uv_project_self_exclusion_source",
        interpreter = interpreter,
        srcs = [
            Label(":self_exclusion_backend/backend.py"),
            Label(":self_exclusion_backend/pyproject.toml"),
        ],
    )
    installs = {
        name: str(Label(":self_exclusion_" + name + "_install"))
        for name in ["a", "b", "c", "unused"]
    }
    declare_project(
        name = "uv_project_self_exclusion_test",
        build_component_owners = {name: name for name in installs},
        build_deps = {
            "packages": {
                name: [{
                    "deps": [install, "//private/build_deps/sccs:" + name],
                    "markers": {"": 1},
                }]
                for name, install in installs.items()
            },
            "scc_graph": {
                "a": {
                    installs["a"]: {"": 1},
                    "//private/build_deps/sccs:c": {"python_version >= '3.10'": 1},
                },
                "b": {
                    installs["b"]: {"": 1},
                    "//private/build_deps/sccs:a": {"": 1},
                },
                "c": {installs["c"]: {"": 1}},
                # This root also reaches A but is not a discovered requirement.
                "unused": {
                    installs["unused"]: {"": 1},
                    "//private/build_deps/sccs:a": {"": 1},
                },
            },
        },
        dep_to_scc = {},
        scc_deps = {},
        scc_graph = {},
    )
    sdist_build(
        name = "uv_project_self_exclusion_sdist",
        src = "@uv_project_self_exclusion_source//:source.tar.gz",
        available_deps_file = "@uv_project_self_exclusion_test__build_graph//:available_deps.json",
        build_deps_file = "@uv_project_self_exclusion_test__build_graph//:build_deps.json",
        configure_interpreter = interpreter,
        dependency_records = "@uv_project_self_exclusion_test__build_graph//:BUILD.bazel",
        deps = [Label("@pypi//build")],
        package_install = installs["a"],
        version = "0.0.1",
    )
    _graph_layout(
        name = "uv_project_self_exclusion_layout",
        project_build = "@uv_project_self_exclusion_test__build_graph//:BUILD.bazel",
        source_build = "@uv_project_self_exclusion_sdist//:BUILD.bazel",
    )
    return module_ctx.extension_metadata(reproducible = True)

self_exclusion_fixture = module_extension(implementation = _self_exclusion_fixture_impl)
