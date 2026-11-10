"""Helpers for generating select()-based aliases and their markers."""

load("@bazel_lib//lib:base64.bzl", "base64")
load("//uv/private/pprint:defs.bzl", "indent", "pprint")

# Selected by aliases when no marker matches. Visibility must be
# //:__subpackages__ because those aliases live in //:.
EMPTY_LIBRARY = """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//:__subpackages__"],
)
"""

def project_package_label(name):
    """Return the distribution's runtime alias in this project."""
    return "//private/distributions/{}:{}".format(name, name)

def _scc_label(scc, owners):
    return "//private/distributions/{}:_scc__{}".format(owners[scc], scc)

MARKER_BUCKET_COUNT = 64
MARKERS_LOAD = 'load("@aspect_rules_py//uv/private/markers:defs.bzl", "decide_marker")'

def marker_bucket(expr):
    return hash(expr) % MARKER_BUCKET_COUNT

def marker_name(expr):
    # URL-safe base64 is injective even for expressions in the same bucket.
    return "marker_" + base64.encode(expr).replace("/", "_").replace("+", "-").rstrip("=")

def marker_interner(marker_table):
    """Cache stable select labels and record which markers a source build uses."""

    def marker(expr):
        if expr not in marker_table:
            marker_table[expr] = "//private/markers/{}:{}".format(marker_bucket(expr), marker_name(expr))
        return marker_table[expr]

    return marker

def marker_declaration(name, expr):
    return """
decide_marker(
    name = "{name}",
    marker = {marker},
    visibility = ["//:__subpackages__"],
)
""".format(name = name, marker = repr(expr))

def write_markers(repository_ctx, marker_table):
    """Write the marker packages required by a source build."""
    buckets = {}
    for expr in sorted(marker_table):
        label = marker_table[expr]
        path, _, name = label[2:].partition(":")
        buckets.setdefault(path, [MARKERS_LOAD]).append(marker_declaration(name, expr))
    for path, content in buckets.items():
        repository_ctx.file(path + "/BUILD.bazel", "\n".join(content))

def select_alias(name, arms, visibility, testonly = False):
    return """
alias(
    name = "{name}",{testonly}
    actual = select({arms}),
    visibility = ["{visibility}"],
)
""".format(
        name = name,
        arms = indent(pprint(arms), " " * 4).lstrip(),
        visibility = visibility,
        testonly = "\n    testonly = True," if testonly else "",
    )

def conditional_dep(content, dep, markers, cond_id, marker_fn, no_match, testonly = False):
    """Return an unconditional dependency or append its marker-selected alias."""
    if "" in markers:
        return dep
    cases = {marker_fn(marker): dep for marker in markers}
    cases["//conditions:default"] = no_match
    content.append(select_alias(cond_id, cases, "//:__subpackages__", testonly))
    return ":" + cond_id

def build_package_select_arms(scc_cfgs, installs_by_scc, package, marker_fn, scc_owners):
    """Build cfg_arms and whl_cfg_arms for a single per-dep-group package alias.

    Args:
        scc_cfgs:   {scc_id: {marker_expr: 1}} — SCCs this package belongs to
                    under the current dep-group config, each annotated with the
                    marker expressions that activate the SCC ("" = always active).
        installs_by_scc: {scc_id: canonical install label} for this package.
        package:    Normalized package name (e.g. "iniconfig").
        scc_owners: {scc_id: distribution} locating each SCC in this project.
        marker_fn:  str → str — converts a raw marker expression into its
                    corresponding config_setting label.

    Returns:
        (cfg_arms, whl_cfg_arms) — both are {label: target} dicts suitable for
        select(). Both are guaranteed to contain a "//conditions:default" arm so
        the select() is always total (Bazel rejects non-total alias selects).

        For packages that are exclusively marker-gated (no unconditional SCC),
        the default arms point at the empty-SCC fallback and //private/sccs:empty_whl,
        making inactive deps a no-op instead of a build failure.
    """
    cfg_arms = {}
    whl_cfg_arms = {}

    for scc, markers in scc_cfgs.items():
        # override_repo can give the selected install a different repository name.
        install = installs_by_scc.get(scc)
        whl_for_pkg = install.replace(":install", ":whl") if install else None

        if "" in markers:
            if "//conditions:default" in cfg_arms:
                fail("Configuration conflict: package '{}' has more than one unconditional SCC".format(package))
            cfg_arms["//conditions:default"] = _scc_label(scc, scc_owners)
            if whl_for_pkg:
                whl_cfg_arms["//conditions:default"] = whl_for_pkg
        else:
            for marker in markers.keys():
                ml = marker_fn(marker)
                if ml in cfg_arms:
                    fail("Configuration conflict: package '{}' has two SCCs for marker '{}'".format(package, marker))
                cfg_arms[ml] = _scc_label(scc, scc_owners)
                if whl_for_pkg:
                    whl_cfg_arms[ml] = whl_for_pkg

    if "//conditions:default" not in cfg_arms:
        cfg_arms["//conditions:default"] = "//private/sccs:empty"

    if "//conditions:default" not in whl_cfg_arms:
        whl_cfg_arms["//conditions:default"] = "//private/sccs:empty_whl"

    return cfg_arms, whl_cfg_arms
