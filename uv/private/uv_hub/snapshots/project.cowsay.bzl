load("@aspect_rules_py//py:defs.bzl", "py_library")
alias = native.alias
config_setting = native.config_setting
exports_files = native.exports_files
filegroup = native.filegroup

def define():
    # cowsay
    # {
    #     "aspect_rules_py": {
    #         "cowsay__6_1": {
    #             "": 1,
    #         },
    #     },
    # }


    alias(
        name = "_package_cowsay_aspect_rules_py",
        actual = select({
            "//conditions:default": "//private/distributions/cowsay:_scc__cowsay__6_1",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "_package_cowsay_aspect_rules_py_whl",
        actual = select({
            "//conditions:default": "@@+uv+whl_install__aspect_rules_py__cowsay__6_1//:whl",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "cowsay",
        actual = select({
            "//private/dep_group:aspect_rules_py": ":_package_cowsay_aspect_rules_py",
        }),
        visibility = ["//visibility:public"],
    )


    alias(
        name = "cowsay_whl",
        actual = select({
            "//private/dep_group:aspect_rules_py": ":_package_cowsay_aspect_rules_py_whl",
        }),
        visibility = ["//visibility:public"],
    )


    # scc: cowsay__6_1
    # members:
    # {
    #     "@@+uv+whl_install__aspect_rules_py__cowsay__6_1//:install": {
    #         "": 1,
    #     },
    # }
    # deps:
    # {}


    py_library(
        name = "_scc__cowsay__6_1",
        deps = [
            "@@+uv+whl_install__aspect_rules_py__cowsay__6_1//:install",
        ],
        visibility = ["//:__subpackages__"],
    )
