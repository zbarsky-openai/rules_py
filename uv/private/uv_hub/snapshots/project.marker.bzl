load("@aspect_rules_py//uv/private/markers:defs.bzl", "decide_marker")
alias = native.alias
config_setting = native.config_setting
exports_files = native.exports_files
filegroup = native.filegroup

def define():
    decide_marker(
        name = "marker_cHl0aG9uX2Z1bGxfdmVyc2lvbiA8ICczLjExJw",
        marker = "python_full_version < '3.11'",
        visibility = ["//:__subpackages__"],
    )
