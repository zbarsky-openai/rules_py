load("//uv/private/pprint:defs.bzl", "indent", "pprint")
load("//uv/private/uv_project:build_deps.bzl", "BUILD_DEPS_LOAD", "PY_LIBRARY_LOAD", "render_build_deps", "write_build_dep_records")
load("//uv/private/uv_project:select_gen.bzl", "EMPTY_LIBRARY", "MARKERS_LOAD", "MARKER_BUCKET_COUNT", "build_package_select_arms", "conditional_dep", "marker_bucket", "marker_declaration", "marker_interner", "marker_name", "project_package_label", "select_alias")

def _add_aliases(content, package, cfgs, installs_by_scc, owners, testonly, _marker):
    content.append("""
# {}
{}
""".format(package, indent(pprint(cfgs), "# ")))
    main_arms = {}
    whl_main_arms = {}

    # FIXME: Handle markers for distinct versions
    for cfg, scc_cfgs in cfgs.items():
        cfg_name = "_package_{}_{}".format(package, cfg)
        whl_cfg_name = cfg_name + "_whl"
        cfg_label = "//private/dep_group:" + cfg
        main_arms[cfg_label] = ":" + cfg_name
        whl_main_arms[cfg_label] = ":" + whl_cfg_name

        cfg_arms, whl_cfg_arms = build_package_select_arms(
            scc_cfgs = scc_cfgs,
            installs_by_scc = installs_by_scc,
            package = package,
            marker_fn = _marker,
            scc_owners = owners,
        )
        content.append(select_alias(cfg_name, cfg_arms, "//visibility:private", testonly))
        content.append(select_alias(whl_cfg_name, whl_cfg_arms, "//visibility:private"))

    content.append(select_alias(package, main_arms, "//visibility:public", testonly))
    content.append(select_alias(package + "_whl", whl_main_arms, "//visibility:public"))

def _add_component(content, scc_id, members, this_scc_deps, testonly, _marker):
    deps = []
    content.append("""
# scc: {}
# members:
{}
# deps:
{}
""".format(scc_id, indent(pprint(members), "# "), indent(pprint(this_scc_deps), "# ")))

    for i, (member, markers) in enumerate(members.items()):
        deps.append(conditional_dep(
            content,
            member,
            markers,
            "_maybe__{}__member_{}".format(scc_id, i),
            _marker,
            "//private/sccs:empty",
            testonly = testonly,
        ))

    # SCC deps are mapped back to surface packages
    for i, (dep, markers) in enumerate(this_scc_deps.items()):
        deps.append(conditional_dep(
            content,
            dep if dep.startswith("@") or dep.startswith("//") else project_package_label(dep),
            markers,
            "_maybe__{}__dep_{}".format(scc_id, i),
            _marker,
            "//private/sccs:empty",
            testonly = testonly,
        ))

    content.append("""
py_library(
    name = "{name}",{testonly}
    deps = {deps},
    visibility = ["//:__subpackages__"],
)
""".format(
        name = "_scc__" + scc_id,
        deps = indent(pprint(deps), " " * 4).lstrip(),
        testonly = "\n    testonly = True," if testonly else "",
    ))

def _distribution(data, refs, marker_fn):
    content = []
    if "cfgs" in data:
        installs = {component: refs.get(label, label) for component, label in data["installs"].items()}
        _add_aliases(content, data["name"], data["cfgs"], installs, data["owners"], data["testonly"], marker_fn)
    for scc_id, (members, deps, testonly) in data["components"].items():
        _add_component(content, scc_id, _canonical_keys(members, refs), _canonical_keys(deps, refs), testonly, marker_fn)
    return content

def _dep_groups(groups):
    return ["""
config_setting(
    name = "{name}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = cfg_name) for cfg_name in groups]

def _surface(packages, testonly_packages, installs):
    root_content = []
    for package in packages:
        root_content.append("""
alias(
    name = "{name}",{testonly}
    actual = "{actual}",
    visibility = ["//visibility:public"],
)

alias(
    name = "{name}_whl",
    actual = "{actual}_whl",
    visibility = ["//visibility:public"],
)
""".format(name = package, actual = project_package_label(package), testonly = "\n    testonly = True," if package in testonly_packages else ""))

    root_content.append("""
alias(
    name = "empty_whl",
    actual = "//private/sccs:empty_whl",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "gazelle_index_whls",
    srcs = {gazelle_whls},
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
        gazelle_whls = indent(pprint([it.replace("//:install", "//:whl") for it in installs]), " " * 4).lstrip(),
    ))

    return root_content

_EMPTY_BUILD = EMPTY_LIBRARY + """
filegroup(
    name = "empty_whl",
    visibility = ["//visibility:public"],
)
exports_files(["BUILD.bazel"], visibility = ["//visibility:public"])
"""

def _partition_build_deps(build, distributions, owners):
    # Source frontends normally use the selected requirement and its dependency
    # components. The project-level aggregate files remain available separately.
    component_labels = {
        "//private/build_deps/sccs:" + component: "//private/build_deps/packages/%s:_scc__%s" % (owners[component], component)
        for component in build["scc_graph"]
    }

    def part(name):
        distribution = distributions.setdefault(name, {"components": {}})
        return distribution.setdefault("build", {"packages": {}, "scc_graph": {}})

    for name, candidates in build["packages"].items():
        part(name)["packages"][name] = [
            {"markers": c["markers"], "deps": [component_labels.get(dep, dep) for dep in c["deps"]]}
            for c in candidates
        ]
    for component, deps in build["scc_graph"].items():
        part(owners[component])["scc_graph"]["_scc__" + component] = {component_labels.get(label, label): markers for label, markers in deps.items()}

def partition_project(dep_to_scc, scc_graph, scc_deps, testonly_packages, build_deps, build_component_owners):
    """Partition the project graph into the inputs for each generated repository."""
    owners = {}
    testonly_sccs = {}
    all_cfgs = {}
    exprs = {}
    names = sorted(dep_to_scc)
    distributions = {}
    for name in names:
        cfgs = dep_to_scc[name]
        testonly = name in testonly_packages
        package_owners = {}

        # The first distribution in lexical order owns the shared component.
        for cfg, components in cfgs.items():
            all_cfgs[cfg] = True
            for component, markers in components.items():
                package_owners[component] = owners.setdefault(component, name)
                if testonly:
                    testonly_sccs[component] = True
                if "" not in markers:
                    exprs.update(markers)

        distributions[name] = {
            "name": name,
            "cfgs": cfgs,
            "testonly": testonly,
            "owners": package_owners,
            # Avoid copying every member of a shared cycle into each spec.
            "installs": {},
            "components": {},
        }
    index_installs = {}
    for component in sorted(scc_graph):
        members = {}

        # Preserve lexical preference if a cycle contains two versions of a package.
        for install, package, markers in sorted(scc_graph[component], key = lambda member: member[0]):
            members[install] = markers
            if package in dep_to_scc and component in distributions[package]["owners"]:
                distributions[package]["installs"].setdefault(component, install)
        index_installs.update(members)
        owner = owners.get(component, "_unselected")
        distribution = distributions.setdefault(owner, {"components": {}})
        deps = scc_deps.get(component, {})
        distribution["components"][component] = [members, deps, component in testonly_sccs]
        for edges in (members, deps):
            for markers in edges.values():
                if "" not in markers:
                    exprs.update(markers)

    if build_deps:
        _partition_build_deps(build_deps, distributions, build_component_owners)
        for members in build_deps["scc_graph"].values():
            for markers in members.values():
                if "" not in markers:
                    exprs.update(markers)
        for candidates in build_deps["packages"].values():
            for candidate in candidates:
                for expr in candidate["markers"]:
                    if expr:
                        exprs[expr] = True
    return struct(
        distributions = distributions,
        groups = sorted(all_cfgs),
        index_installs = list(index_installs),
        exprs = sorted(exprs),
        names = names,
    )

def _module(ctx, path, loads, declarations):
    # Legacy macros instantiate in the public project's package. In particular
    # its repository is still the owner used by PyInfo imports and runfiles.
    body = "\n".join(declarations).strip()
    lines = ["    " + line if line else "" for line in body.splitlines()] if body else ["    pass"]
    ctx.file(path, loads + """
alias = native.alias
config_setting = native.config_setting
exports_files = native.exports_files
filegroup = native.filegroup

def define():
""" + "\n".join(lines) + "\n")

def _label_refs(labels):
    # Convert generated apparent labels when the extension declares the repository.
    # Legacy macros instantiate in the public project. A member's install label
    # must not introduce that install into the public project's repository map.
    apparent = [label for label in labels if label.startswith("@") and not label.startswith("@@")]
    return {label: label for label in sorted(apparent)}

def _canonical_refs(refs):
    return {label: str(target) for label, target in refs.items()}

def _canonical_keys(values, refs):
    return {refs.get(k, k): v for k, v in values.items()}

def _add_build_labels(labels, graph):
    for deps in graph["scc_graph"].values():
        labels.update(deps)
    for candidates in graph["packages"].values():
        for candidate in candidates:
            for label in candidate["deps"]:
                labels[label] = True

def _resolve_build_labels(graph, refs):
    for candidates in graph["packages"].values():
        for candidate in candidates:
            candidate["deps"] = [refs.get(label, label) for label in candidate["deps"]]
    graph["scc_graph"] = {key: _canonical_keys(deps, refs) for key, deps in graph["scc_graph"].items()}

def _write_defs(ctx, declarations, loads = ""):
    _module(ctx, "defs.bzl", loads, declarations)
    ctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')

def _member_impl(ctx):
    data = json.decode(ctx.attr.data)
    refs = _canonical_refs(ctx.attr.refs)
    marker_fn = marker_interner({})
    _write_defs(ctx, _distribution(data, refs, marker_fn), PY_LIBRARY_LOAD)
    if "build" in data:
        graph = data["build"]
        _resolve_build_labels(graph, refs)
        decls = render_build_deps(graph["packages"], graph["scc_graph"], marker_fn)
        _module(ctx, "build.bzl", BUILD_DEPS_LOAD, decls.components + decls.requirements)
    return ctx.repo_metadata(reproducible = True)

_member = repository_rule(implementation = _member_impl, attrs = {"data": attr.string(), "refs": attr.string_keyed_label_dict()})

def _marker_repo_impl(ctx):
    exprs = ctx.attr.exprs
    _write_defs(ctx, [marker_declaration(marker_name(expr), expr) for expr in exprs], MARKERS_LOAD if exprs else "")
    return ctx.repo_metadata(reproducible = True)

_marker_repo = repository_rule(implementation = _marker_repo_impl, attrs = {"exprs": attr.string_list()})

def _surface_impl(ctx):
    testonly_packages = {name: True for name in ctx.attr.testonly_packages}
    _write_defs(ctx, _surface(ctx.attr.packages, testonly_packages, [str(label) for label in ctx.attr.installs]))
    return ctx.repo_metadata(reproducible = True)

_surface_repo = repository_rule(
    implementation = _surface_impl,
    attrs = {
        "installs": attr.label_list(),
        "packages": attr.string_list(),
        "testonly_packages": attr.string_list(),
    },
)

def _groups_impl(ctx):
    _write_defs(ctx, _dep_groups(ctx.attr.groups))
    return ctx.repo_metadata(reproducible = True)

_groups_repo = repository_rule(implementation = _groups_impl, attrs = {"groups": attr.string_list()})

def _build_graph_impl(ctx):
    graph = json.decode(ctx.attr.graph)
    prefix = "@@" + ctx.attr.project.repo_name + "//private/build_deps/packages/"
    available = {name: prefix + name + ":" + name for name in graph["packages"]}
    _resolve_build_labels(graph, _canonical_refs(ctx.attr.refs))
    ctx.file("build_deps.json", json.encode(graph))
    ctx.file("available_deps.json", json.encode(available))
    write_build_dep_records(ctx, available, graph)

    decls = render_build_deps(graph["packages"], graph["scc_graph"], marker_interner({}))
    _module(ctx, "components.bzl", PY_LIBRARY_LOAD + "\n", decls.components)
    _module(ctx, "packages.bzl", BUILD_DEPS_LOAD + "\n", decls.requirements)
    ctx.file("BUILD.bazel", 'exports_files(["available_deps.json", "build_deps.json", "components.bzl", "packages.bzl"])')
    return ctx.repo_metadata(reproducible = True)

_build_graph = repository_rule(
    implementation = _build_graph_impl,
    attrs = {"project": attr.label(), "graph": attr.string(), "refs": attr.string_keyed_label_dict()},
)

def _stub(source):
    return 'load("{}", "define")\n\ndefine()\n'.format(source)

def _facade_impl(ctx):
    # BUILD files must work when Bazel restores just this repository from its
    # contents cache. A Starlark load asks Bazel to fetch the referenced member.
    for name, member in ctx.attr.members.items():
        ctx.file(
            "private/distributions/{}/BUILD.bazel".format(name),
            _stub("@@{}//:defs.bzl".format(member.repo_name)),
        )
    for name in ctx.attr.build_members:
        ctx.file(
            "private/build_deps/packages/{}/BUILD.bazel".format(name),
            _stub("@@{}//:build.bzl".format(ctx.attr.members[name].repo_name)),
        )

    def backing(suffix, target = "defs.bzl"):
        return "@@{}//:{}".format(ctx.attr.backings[suffix].repo_name, target)

    for i in range(MARKER_BUCKET_COUNT):
        ctx.file("private/markers/{}/BUILD.bazel".format(i), _stub(backing("marker_{}".format(i))))
    root = _stub(backing("surface"))
    if "build_graph" in ctx.attr.backings:
        for path in ["available_deps.json", "build_deps.json"]:
            root += 'alias(name = "{}", actual = "{}", visibility = ["//visibility:public"])\n'.format(path, backing("build_graph", path))
        ctx.file("private/build_deps/BUILD.bazel", _stub(backing("build_graph", "packages.bzl")))
        ctx.file("private/build_deps/sccs/BUILD.bazel", _stub(backing("build_graph", "components.bzl")))
    ctx.file("BUILD.bazel", root)
    ctx.file("private/sccs/BUILD.bazel", _EMPTY_BUILD)
    ctx.file("private/dep_group/BUILD.bazel", _stub(backing("groups")))
    return ctx.repo_metadata(reproducible = True)

_facade = repository_rule(
    implementation = _facade_impl,
    attrs = {
        "backings": attr.string_keyed_label_dict(),
        "members": attr.string_keyed_label_dict(),
        "build_members": attr.string_list(),
    },
)

def declare_project(name, build_deps, dep_to_scc, scc_deps, scc_graph, build_component_owners, testonly_packages = {}):
    """Declare lazy dependency repositories plus the project's stable Bazel package entry points."""
    parts = partition_project(dep_to_scc, scc_graph, scc_deps, testonly_packages, build_deps, build_component_owners)
    backings = {}

    def backing(suffix):
        repo = name + "__" + suffix
        backings[suffix] = "@" + repo + "//:BUILD.bazel"
        return repo

    members = {}
    build_members = []
    for member in sorted(parts.distributions):
        data = parts.distributions[member]
        labels = {label: True for label in data.get("installs", {}).values()}
        for installs, deps, _ in data["components"].values():
            labels.update(installs)
            labels.update(deps)
        if "build" in data:
            build_members.append(member)
            _add_build_labels(labels, data["build"])
        repo = name + "__distribution_" + member
        members[member] = "@" + repo + "//:BUILD.bazel"
        _member(
            name = repo,
            data = json.encode(data),
            refs = _label_refs(labels),
        )

    buckets = [[] for _ in range(MARKER_BUCKET_COUNT)]
    for expr in parts.exprs:
        buckets[marker_bucket(expr)].append(expr)
    for i, exprs in enumerate(buckets):
        _marker_repo(name = backing("marker_%s" % i), exprs = exprs)
    _surface_repo(name = backing("surface"), packages = parts.names, testonly_packages = sorted(testonly_packages), installs = parts.index_installs)
    _groups_repo(name = backing("groups"), groups = parts.groups)
    if build_deps != None:
        labels = {}
        _add_build_labels(labels, build_deps)
        _build_graph(
            name = backing("build_graph"),
            project = "@" + name + "//:BUILD.bazel",
            graph = json.encode(build_deps),
            refs = _label_refs(labels),
        )
    _facade(
        name = name,
        backings = backings,
        members = members,
        build_members = build_members,
    )
