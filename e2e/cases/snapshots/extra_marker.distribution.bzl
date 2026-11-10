load("@aspect_rules_py//py:defs.bzl", "py_library")
alias = native.alias
config_setting = native.config_setting
exports_files = native.exports_files
filegroup = native.filegroup

def define():
    # extra_marker
    # {
    #     "ci": {
    #         "extra_marker__0_0_0": {
    #             "": 1,
    #         },
    #     },
    # }


    alias(
        name = "_package_extra_marker_ci",
        actual = select({
            "//conditions:default": "//private/distributions/extra_marker:_scc__extra_marker__0_0_0",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "_package_extra_marker_ci_whl",
        actual = select({
            "//conditions:default": "//private/sccs:empty_whl",
        }),
        visibility = ["//visibility:private"],
    )


    alias(
        name = "extra_marker",
        actual = select({
            "//private/dep_group:ci": ":_package_extra_marker_ci",
        }),
        visibility = ["//visibility:public"],
    )


    alias(
        name = "extra_marker_whl",
        actual = select({
            "//private/dep_group:ci": ":_package_extra_marker_ci_whl",
        }),
        visibility = ["//visibility:public"],
    )


    # scc: extra_marker__0_0_0
    # members:
    # {}
    # deps:
    # {
    #     "colorama": {
    #         "": 1,
    #     },
    # }


    py_library(
        name = "_scc__extra_marker__0_0_0",
        deps = [
            "//private/distributions/colorama:colorama",
        ],
        visibility = ["//:__subpackages__"],
    )
