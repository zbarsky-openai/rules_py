load("@aspect_rules_py//py:defs.bzl", "py_library")
alias = native.alias
config_setting = native.config_setting
exports_files = native.exports_files
filegroup = native.filegroup

def define():
    # cowsay
    # {
    #     "single_project_hub": {
    #         "cowsay__6_1": {
    #             "": 1,
    #         },
    #     },
    # }


    alias(
        name = "_package_cowsay_single_project_hub",
        actual = select({
            "//conditions:default": "//private/distributions/cowsay:_scc__cowsay__6_1",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "_package_cowsay_single_project_hub_whl",
        actual = select({
            "//conditions:default": "@@aspect_rules_py++uv+whl_install__aspect_rules_py__cowsay__6_1//:whl",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "cowsay",
        actual = select({
            "//private/dep_group:single_project_hub": ":_package_cowsay_single_project_hub",
        }),
        visibility = ["//visibility:public"],
    )


    alias(
        name = "cowsay_whl",
        actual = select({
            "//private/dep_group:single_project_hub": ":_package_cowsay_single_project_hub_whl",
        }),
        visibility = ["//visibility:public"],
    )


    # scc: cowsay__6_1
    # members:
    # {
    #     "@@aspect_rules_py++uv+whl_install__aspect_rules_py__cowsay__6_1//:install": {
    #         "": 1,
    #     },
    # }
    # deps:
    # {}


    py_library(
        name = "_scc__cowsay__6_1",
        deps = [
            "@@aspect_rules_py++uv+whl_install__aspect_rules_py__cowsay__6_1//:install",
        ],
        visibility = ["//:__subpackages__"],
    )
