load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/uv_project:repository.bzl", "partition_project")
load("//uv/private/uv_project:select_gen.bzl", "build_package_select_arms", "marker_interner")

def _marker_label(expr):
    return "//private/markers:" + expr

def _inactive_markers_test_impl(ctx):
    env = unittest.begin(ctx)
    for expr in [
        "sys_platform == 'win32'",
        "sys_platform == 'win32' and python_full_version >= '3.12'",
        "sys_platform == 'win32' or python_full_version >= '3.12'",
    ]:
        cfg, whl = build_package_select_arms(
            scc_cfgs = {"scc_ini": {expr: 1}},
            installs_by_scc = {},
            package = "iniconfig",
            marker_fn = _marker_label,
            scc_owners = {"scc_ini": "iniconfig"},
        )
        asserts.equals(env, {
            _marker_label(expr): "//private/distributions/iniconfig:_scc__scc_ini",
            "//conditions:default": "//private/sccs:empty",
        }, cfg, expr)
        asserts.equals(env, {"//conditions:default": "//private/sccs:empty_whl"}, whl, expr)
    return unittest.end(env)

_inactive_markers_test = unittest.make(_inactive_markers_test_impl)

def _active_package_test_impl(ctx):
    env = unittest.begin(ctx)

    # override_repo can point an install at a repository with a different name.
    for installs, expected_whl in [
        ({}, "//private/sccs:empty_whl"),
        ({"scc_tqdm": "@@+local_repos+fixture//:install"}, "@@+local_repos+fixture//:whl"),
    ]:
        cfg, whl = build_package_select_arms(
            scc_cfgs = {"scc_tqdm": {"": 1}},
            installs_by_scc = installs,
            package = "tqdm",
            marker_fn = _marker_label,
            scc_owners = {"scc_tqdm": "tqdm"},
        )
        asserts.equals(env, {"//conditions:default": "//private/distributions/tqdm:_scc__scc_tqdm"}, cfg)
        asserts.equals(env, {"//conditions:default": expected_whl}, whl)
    return unittest.end(env)

_active_package_test = unittest.make(_active_package_test_impl)

def _shared_cycle_wheels_test_impl(ctx):
    env = unittest.begin(ctx)

    # Dedup moved aaa's install to project foo. Both install labels contain "foo".
    aaa = "@whl_install__foo__aaa__1//:install"
    foo = "@whl_install__tools__foo__1//:install"
    active = {"": 1}
    cfg = {"tools": {"cycle": active}}
    parts = partition_project(
        dep_to_scc = {"aaa": cfg, "foo": cfg, "native": cfg},
        scc_graph = {"cycle": [(aaa, "aaa", active), (foo, "foo", active), ("//:native", None, active)]},
        scc_deps = {},
        testonly_packages = {},
        build_deps = None,
        build_component_owners = {},
    )
    asserts.equals(env, {"cycle": aaa}, parts.distributions["aaa"]["installs"])
    asserts.equals(env, {"cycle": foo}, parts.distributions["foo"]["installs"])
    asserts.equals(env, {}, parts.distributions["native"]["installs"])
    return unittest.end(env)

_shared_cycle_wheels_test = unittest.make(_shared_cycle_wheels_test_impl)

def _stable_marker_keys_test_impl(ctx):
    env = unittest.begin(ctx)

    # These PEP 508 expressions deliberately share Starlark's string hash.
    a = "os_name == 'Aa'"
    b = "os_name == 'BB'"
    asserts.equals(env, hash(a), hash(b))
    forward = marker_interner({})
    a_first = forward(a)
    b_second = forward(b)
    asserts.false(env, a_first == b_second)
    reverse = marker_interner({})
    asserts.equals(env, b_second, reverse(b))
    asserts.equals(env, a_first, reverse(a))
    return unittest.end(env)

_stable_marker_keys_test = unittest.make(_stable_marker_keys_test_impl)

def select_gen_test_suite():
    unittest.suite(
        "select_gen_tests",
        _stable_marker_keys_test,
        _inactive_markers_test,
        _active_package_test,
        _shared_cycle_wheels_test,
    )
