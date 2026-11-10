"""Generate public package aliases and dependency group files for a Python hub."""

load("//uv/private/pprint:defs.bzl", "indent", "pprint")
load("//uv/private/uv_project:select_gen.bzl", "project_package_label")

def _write_settings(repository_ctx):
    content = [
        """\
alias(
    name = "dep_group",
    actual = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group",
    visibility = ["//visibility:public"],
)
""",
    ]

    for name in repository_ctx.attr.configurations:
        content.append(
            """
config_setting(
    name = "{name}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = name),
        )
    content.append("""
exports_files(
    ["BUILD.bazel"] + glob(["deps/*.bzl"], allow_empty = True),
    visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("dep_group/BUILD.bazel", content = "\n".join(content))

    index_select_clauses = {
        "//dep_group:" + cfg: [str(index)]
        for cfg, index in repository_ctx.attr.configurations.items()
    }

    repository_ctx.file("BUILD.bazel", """\
filegroup(
    name = "gazelle_index_whls",
    srcs = select({index_select_clauses},
    ),
    visibility = ["//visibility:public"],
)

exports_files(
    ["compatibility.bzl", "requirements.bzl"],
    visibility = ["//visibility:public"],
)
""".format(index_select_clauses = indent(pprint(index_select_clauses), "        ").lstrip()))

def _hub_package_build(package_name, groups, configurations, testonly):
    testonly_attr = "\n    testonly = True," if testonly else ""

    package_label = project_package_label(package_name)
    select_spec = {
        "//dep_group:" + group: "@@" + configurations[group].repo_name + package_label
        for group in groups
    }
    whl_select_spec = {condition: label + "_whl" for condition, label in select_spec.items()}

    # When the package itself is named "pkg", the `:{name}` alias below already
    # exposes a `pkg` target — emitting a separate `:pkg` alias would collide.
    pkg_alias = "" if package_name == "pkg" else """\
alias(
    name = "pkg",{testonly}
    actual = "{name}",
    visibility = ["//visibility:public"],
)
""".format(name = package_name, testonly = testonly_attr)

    return """\
load("//:compatibility.bzl", "compatible_with")


{pkg_alias}\
alias(
    name = "whl",
    actual = select({whl_select}),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)
alias(
    name = "{name}",{testonly}
    actual = select({lib_select},
        no_match_error = "{error}",
    ),
    target_compatible_with = select(compatible_with({compat})),
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
        name = package_name,
        pkg_alias = pkg_alias,
        lib_select = indent(pprint(select_spec), "      ").lstrip(),
        whl_select = indent(pprint(whl_select_spec), "      ").lstrip(),
        compat = repr(groups),
        error = "Available only in dep_groups: " + ", ".join(groups),
        testonly = testonly_attr,
    )

def _hub_impl(repository_ctx):
    configurations = repository_ctx.attr.configurations
    packages = repository_ctx.attr.packages
    testonly_packages = {name: True for name in repository_ctx.attr.testonly_packages}
    package_names = sorted(packages.keys())

    _write_settings(repository_ctx)

    # Iterate distributions in order so each group's exported DEPS is sorted.
    deps_by_group = {group: [] for group in configurations}
    for package_name in package_names:
        groups = packages[package_name]
        repository_ctx.file(
            package_name + "/BUILD.bazel",
            _hub_package_build(package_name, groups, configurations, package_name in testonly_packages),
        )

        hub_label = "@@{}//{}:pkg".format(repository_ctx.name, package_name)
        for group in groups:
            deps_by_group[group].append(hub_label)

    for group, deps in deps_by_group.items():
        repository_ctx.file(
            "dep_group/deps/{}.bzl".format(group),
            content = "DEPS = [Label(dep) for dep in {}]\n".format(pprint(deps)),
        )

    # Per-wheel BUILD files need only the environment names and constraints.
    # Keep this module independent of the hub-wide distribution index.
    repository_ctx.file("compatibility.bzl", content = """\
VIRTUALENVS = {configurations}

def compatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {{
        Label("//dep_group:" + it): extra_constraints
        for it in venvs
    }} | {{
        "//conditions:default": ["@platforms//:incompatible"],
    }}

def incompatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {{
        Label("//dep_group:" + it): ["@platforms//:incompatible"]
        for it in venvs
    }} | {{
        "//conditions:default": extra_constraints,
    }}
""".format(configurations = pprint(configurations.keys())))

    repository_ctx.file("requirements.bzl", """
load("@aspect_rules_py//uv/private:normalize_name.bzl", "normalize_name")

all_requirements = {all_requirements}

all_whl_requirements_by_package = {all_whl_requirements_by_package}

all_whl_requirements = all_whl_requirements_by_package.values()

all_data_requirements = all_requirements

def requirement(name):
    return "@@{repo_name}//{{0}}:pkg".format(normalize_name(name))
""".format(
        all_requirements = repr([
            "@@{0}//{1}:pkg".format(repository_ctx.name, name)
            for name in package_names
        ]),
        all_whl_requirements_by_package = repr({
            name: "@@{0}//{1}:whl".format(repository_ctx.name, name)
            for name in package_names
        }),
        repo_name = repository_ctx.name,
    ))

    return repository_ctx.repo_metadata(reproducible = True)

uv_hub = repository_rule(
    doc = """
    Generates the surface hub repository exposed to the build.

    - `compatibility.bzl`: environment names and compatibility helpers.
    - `//dep_group:deps/<group>.bzl`: the ordered list of package Labels for
      the named group, exported as `DEPS`. Set the consuming target's
      `dep_group` to select matching wheel implementations.
    - `requirements.bzl`: the rules_python-compatible hub-wide requirements.
    """,
    implementation = _hub_impl,
    attrs = {
        "configurations": attr.string_keyed_label_dict(
            doc = "Project wheel-index label for each dependency group.",
        ),
        "packages": attr.string_list_dict(doc = "Sorted dependency groups containing each distribution."),
        "testonly_packages": attr.string_list(),
    },
)
