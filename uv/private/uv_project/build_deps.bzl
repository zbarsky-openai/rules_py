"""Render a build-dependency graph in a project or source-build repository."""

load("//uv/private/extension:graph_utils.bzl", "reachable_build_deps")
load("//uv/private/pprint:defs.bzl", "indent", "pprint")
load("//uv/private/uv_project:select_gen.bzl", "EMPTY_LIBRARY", "conditional_dep", "marker_interner", "write_markers")

def _unresolved_build_requirement_impl(ctx):
    fail("Build requirement '{}' has multiple locked versions without disjoint resolution markers.".format(ctx.attr.requirement))

unresolved_build_requirement = rule(
    implementation = _unresolved_build_requirement_impl,
    attrs = {"requirement": attr.string(mandatory = True)},
)

def write_build_dep_records(repository_ctx, available_deps, build_deps):
    """Write each requirement's label, candidates, and complete build closure."""
    packages = build_deps["packages"]
    graph = build_deps["scc_graph"]
    for name, candidates in packages.items():
        repository_ctx.file("build_deps_records/" + name + ".json", json.encode({
            "label": available_deps[name],
            "candidates": candidates,
            "scc_graph": reachable_build_deps({name: candidates}, graph),
        }))

def read_build_dep_records(repository_ctx, anchor, names):
    """Read only discovered requirements, watching absent names too."""

    # The exported BUILD file locates the records; its contents are not an input.
    root = repository_ctx.path(anchor).dirname
    available_deps = {}
    packages = {}
    graph = {}
    for name in names:
        record = root.get_child("build_deps_records", name + ".json")
        repository_ctx.watch(record)
        if record.exists:
            data = json.decode(repository_ctx.read(record))
            if data["label"]:
                available_deps[name] = data["label"]
            if data["candidates"]:
                packages[name] = data["candidates"]
            graph.update(data["scc_graph"])
    return available_deps, {"packages": packages, "scc_graph": graph}

PY_LIBRARY_LOAD = 'load("@aspect_rules_py//py:defs.bzl", "py_library")'
BUILD_DEPS_LOAD = PY_LIBRARY_LOAD + '\nload("@aspect_rules_py//uv/private/uv_project:build_deps.bzl", "unresolved_build_requirement")'

def render_build_deps(packages, scc_graph, marker_fn):
    """Render the two sets of declarations shared by project modules and sdist BUILD files."""
    components = []
    for scc_id, members in scc_graph.items():
        # Ordinals make private conditional aliases unique within each SCC.
        deps = [
            conditional_dep(components, member, markers, "_maybe__{}__member_{}".format(scc_id, i), marker_fn, "//private/sccs:empty")
            for i, (member, markers) in enumerate(members.items())
        ]
        components.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//:__subpackages__"],
)
""".format(
            name = scc_id,
            deps = indent(pprint(deps), " " * 4).lstrip(),
        ))
    requirements = []
    for package, candidates in packages.items():
        arms = {}
        ambiguous = False
        for candidate in candidates:
            markers = candidate["markers"]
            if "" in markers:
                if len(candidates) > 1:
                    ambiguous = True
                markers = {"": 1}
            for marker in sorted(markers):
                condition = marker_fn(marker) if marker else "//conditions:default"
                if condition in arms and arms[condition] != candidate["deps"]:
                    ambiguous = True
                arms[condition] = candidate["deps"]

        if ambiguous:
            # Unrelated runtime groups can use a multi-version lock without
            # requesting this ambiguous build requirement.
            requirements.append("""
unresolved_build_requirement(
    name = {name},
    requirement = {name},
    visibility = ["//visibility:public"],
)
""".format(name = repr(package)))
            continue

        # Select the requested install and its closure together. The install
        # must remain direct even when a cycle reaches it conditionally.
        if len(arms) == 1 and "//conditions:default" in arms:
            deps = indent(pprint(arms["//conditions:default"]), " " * 4).lstrip()
        else:
            deps = "select({}, no_match_error = {})".format(
                indent(pprint(arms), " " * 4).lstrip(),
                repr("No locked version of build requirement '{}' matches the current Python/platform configuration.".format(package)),
            )
        requirements.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//visibility:public"],
)
""".format(
            name = package,
            deps = deps,
        ))
    return struct(components = components, requirements = requirements)

def write_build_deps(repository_ctx, packages, scc_graph):
    """Write the selected build requirements and their local closure for an sdist."""
    marker_table = {}
    decls = render_build_deps(packages, scc_graph, marker_interner(marker_table))
    repository_ctx.file("private/build_deps/sccs/BUILD.bazel", "\n".join([PY_LIBRARY_LOAD + "\n"] + decls.components))
    repository_ctx.file("private/build_deps/BUILD.bazel", "\n".join([BUILD_DEPS_LOAD + "\n"] + decls.requirements))
    if marker_table:
        repository_ctx.file("private/sccs/BUILD.bazel", EMPTY_LIBRARY)
        write_markers(repository_ctx, marker_table)
