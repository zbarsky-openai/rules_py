load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/extension:lockfile.bzl", "normalize_lock")
load("//uv/private/markers:pep508_evaluate.bzl", "evaluate")
load("//uv/private/extension:projectfile.bzl", "collect_activated_extras", "extract_requirement_marker_pairs")

def _locked_versions(name, versions):
    return {name: {version: ("proj", name, version, "__base__") for version in versions}}

def _extract_requirement_marker_pairs_multi_version_no_specifier_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "build",
        {},
        _locked_versions("build", ["1.3.0", "1.4.0"]),
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.4.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_multi_version_no_specifier_test = unittest.make(
    _extract_requirement_marker_pairs_multi_version_no_specifier_test_impl,
)

def _extract_requirement_marker_pairs_multi_version_with_specifier_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "build>=1.3.0,<1.4.0",
        {},
        _locked_versions("build", ["1.2.0", "1.3.0", "1.4.0"]),
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.3.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_multi_version_with_specifier_test = unittest.make(
    _extract_requirement_marker_pairs_multi_version_with_specifier_test_impl,
)

def _extract_requirement_marker_pairs_single_version_via_map_test_impl(ctx):
    env = unittest.begin(ctx)
    version_map = {"build": ("proj", "build", "1.2.0", "__base__")}
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "build",
        version_map,
        _locked_versions("build", ["1.2.0", "1.3.0"]),
    )
    asserts.equals(env, 1, len(result))
    dep, marker = result[0]
    asserts.equals(env, ("proj", "build", "1.2.0", "__base__"), dep)
    asserts.equals(env, "", marker)
    return unittest.end(env)

extract_requirement_marker_pairs_single_version_via_map_test = unittest.make(
    _extract_requirement_marker_pairs_single_version_via_map_test_impl,
)

def _extract_requirement_marker_pairs_with_extras_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        'build[extra1,extra2] >= 1.0; python_version >= "3.10"',
        {},
        _locked_versions("build", ["1.0.0", "1.1.0"]),
    )
    asserts.equals(env, 3, len(result))
    asserts.equals(env, (("proj", "build", "1.1.0", "__base__"), 'python_version >= "3.10"'), result[0])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra1"), 'python_version >= "3.10"'), result[1])
    asserts.equals(env, (("proj", "build", "1.1.0", "extra2"), 'python_version >= "3.10"'), result[2])
    return unittest.end(env)

extract_requirement_marker_pairs_with_extras_test = unittest.make(
    _extract_requirement_marker_pairs_with_extras_test_impl,
)

def _extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test_impl(ctx):
    env = unittest.begin(ctx)
    result = extract_requirement_marker_pairs(
        "//:pyproject.toml",
        "foo>=2",
        {"foo": ("proj", "foo", "1.9", "__base__")},
        _locked_versions("foo", ["1.9"]),
    )
    asserts.equals(env, [(("proj", "foo", "1.9", "__base__"), "")], result)
    return unittest.end(env)

extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test = unittest.make(
    _extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test_impl,
)

def _locked_platform_forks_test_impl(ctx):
    env = unittest.begin(ctx)
    linux = "sys_platform == 'linux'"
    darwin = "sys_platform == 'darwin'"

    # uv can omit part of the release's domain on an incoming edge.
    # The Darwin wheel must not become reachable on Windows.
    extra = {"demo": [{"name": "addon"}]}
    lock = {"package": [
        {"name": "consumer", "version": "1", "dependencies": [
            {"name": "leaf", "version": "1", "marker": "sys_platform != 'linux'"},
            {"name": "leaf", "version": "2", "marker": linux},
        ]},
        {"name": "leaf", "version": "1", "resolution-markers": [darwin], "optional-dependencies": extra},
        {"name": "leaf", "version": "2", "resolution-markers": [linux], "optional-dependencies": extra},
        {"name": "addon", "version": "1"},
    ]}
    groups = {"transitive": ["consumer", "leaf[demo]==2; " + linux], "exported": ["leaf[demo]"]}
    defaults, versions, graph = normalize_lock("lock", lock)
    _, activated = collect_activated_extras("//:pyproject.toml", "lock", {"project": {"name": "profile"}, "dependency-groups": groups}, lock, defaults, graph, versions)
    for group, expected in {
        "exported": {"darwin": ["addon-1", "leaf-1"], "linux": ["addon-1", "leaf-2"]},
        "transitive": {"darwin": ["leaf-1"], "linux": ["addon-1", "leaf-2"]},
    }.items():
        for platform in ("darwin", "linux", "win32"):
            selected = []
            for dep, configs in activated.items():
                if dep[1] not in ("leaf", "addon"):
                    continue
                markers = configs.get(group, {}).get(dep, {})
                if any([not marker or evaluate(marker, env = {"sys_platform": platform}) for marker in markers]):
                    selected.append(dep[1] + "-" + dep[2])
            asserts.equals(env, expected.get(platform, []), sorted(selected), group + "/" + platform)
    return unittest.end(env)

locked_platform_forks_test = unittest.make(_locked_platform_forks_test_impl)

def _collect_activated_extras_platform_split_transitive_markers_test_impl(ctx):
    env = unittest.begin(ctx)
    darwin = 'sys_platform == "darwin"'
    not_darwin = 'sys_platform != "darwin"'

    # The transitive edges are unconditional because their platform markers are
    # redundant with the direct requirements. The traversal must carry those
    # direct markers forward rather than making both transitive versions global.
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": [
                "platform-parent==1.0; {}".format(darwin),
                "platform-parent==2.0; {}".format(not_darwin),
            ],
        },
    }
    lock_data = {
        "package": [
            {
                "name": "test_project",
                "source": {"virtual": "."},
                "dev-dependencies": {
                    "default": [
                        {"name": "platform-parent", "version": "1.0"},
                        {"name": "platform-parent", "version": "2.0"},
                    ],
                },
            },
        ],
    }
    parent_1 = ("lock", "platform_parent", "1.0", "__base__")
    parent_2 = ("lock", "platform_parent", "2.0", "__base__")
    transitive_1 = ("lock", "transitive_dep", "1.0", "__base__")
    transitive_2 = ("lock", "transitive_dep", "2.0", "__base__")
    graph = {
        parent_1: {transitive_1: {"": 1}},
        parent_2: {transitive_2: {"": 1}},
        transitive_1: {},
        transitive_2: {},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        lock_data,
        {},
        graph,
        {
            "platform_parent": {"1.0": parent_1, "2.0": parent_2},
            "transitive_dep": {"1.0": transitive_1, "2.0": transitive_2},
        },
    )

    asserts.equals(env, {darwin: 1}, activated_extras[transitive_1]["default"][transitive_1])
    asserts.equals(env, {not_darwin: 1}, activated_extras[transitive_2]["default"][transitive_2])
    return unittest.end(env)

collect_activated_extras_platform_split_transitive_markers_test = unittest.make(
    _collect_activated_extras_platform_split_transitive_markers_test_impl,
)

def _collect_activated_extras_conditional_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    root_marker = 'sys_platform == "linux"'
    edge_marker = 'python_version < "3.13"'
    cycle_marker = 'platform_python_implementation == "CPython"'
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": ["package-a==1.0; {}".format(root_marker)],
        },
    }
    package_a = ("lock", "package_a", "1.0", "__base__")
    package_b = ("lock", "package_b", "1.0", "__base__")
    graph = {
        package_a: {package_b: {edge_marker: 1}},
        package_b: {package_a: {cycle_marker: 1}},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        {},
        {},
        graph,
        {
            "package_a": {"1.0": package_a},
            "package_b": {"1.0": package_b},
        },
    )

    asserts.equals(env, {root_marker: 1}, activated_extras[package_a]["default"][package_a])
    asserts.equals(
        env,
        {"({}) and ({})".format(edge_marker, root_marker): 1},
        activated_extras[package_b]["default"][package_b],
    )
    return unittest.end(env)

collect_activated_extras_conditional_cycle_test = unittest.make(
    _collect_activated_extras_conditional_cycle_test_impl,
)

def _collect_activated_extras_clause_rendering_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    a = 'python_version < "3.13"'
    b = 'sys_platform == "linux"'
    rendered = "({}) and ({})".format(a, b)
    project_data = {
        "project": {"name": "test_project"},
        "dependency-groups": {
            "default": [
                "split-parent==1.0; {}".format(a),
                "paren-parent==1.0",
                "plain-parent==1.0",
            ],
        },
    }
    split_parent = ("lock", "split_parent", "1.0", "__base__")
    paren_parent = ("lock", "paren_parent", "1.0", "__base__")
    plain_parent = ("lock", "plain_parent", "1.0", "__base__")
    leaf = ("lock", "leaf", "1.0", "__base__")
    graph = {
        split_parent: {leaf: {b: 1}},
        paren_parent: {leaf: {rendered: 1}},
        plain_parent: {leaf: {"": 1}},
        leaf: {},
    }

    _cfg_names, activated_extras = collect_activated_extras(
        "//:pyproject.toml",
        "lock",
        project_data,
        {},
        {},
        graph,
        {
            "split_parent": {"1.0": split_parent},
            "paren_parent": {"1.0": paren_parent},
            "plain_parent": {"1.0": plain_parent},
            "leaf": {"1.0": leaf},
        },
    )

    asserts.equals(env, {"": 1}, activated_extras[leaf]["default"][leaf])
    return unittest.end(env)

collect_activated_extras_clause_rendering_collision_test = unittest.make(
    _collect_activated_extras_clause_rendering_collision_test_impl,
)

def projectfile_test_suite():
    unittest.suite(
        "extract_requirement_marker_pairs_tests",
        extract_requirement_marker_pairs_multi_version_no_specifier_test,
        extract_requirement_marker_pairs_multi_version_with_specifier_test,
        extract_requirement_marker_pairs_single_version_via_map_test,
        extract_requirement_marker_pairs_with_extras_test,
        extract_requirement_marker_pairs_unsatisfied_single_version_falls_back_test,
        locked_platform_forks_test,
        collect_activated_extras_platform_split_transitive_markers_test,
        collect_activated_extras_conditional_cycle_test,
        collect_activated_extras_clause_rendering_collision_test,
    )
