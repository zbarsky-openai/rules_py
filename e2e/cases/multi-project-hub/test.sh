#!/usr/bin/env bash
# Pin cowsay independently in two projects and check the public extension after each edit.
set -euo pipefail
export LC_ALL=C

case_dir="$(cd "$(dirname "$0")" && pwd)"
rules_py="$(cd "$case_dir/../../.." && pwd)"
scratch="$(mktemp -d)"
run_bazel() { "${BAZEL:-bazel}" --output_base="$scratch/output" "$@"; }
trap 'run_bazel shutdown >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT

mkdir "$scratch/ws"
cd "$scratch/ws"
cp -R "$case_dir" "$case_dir/../.bazelversion" .
chmod u+w multi-project-hub/{beta,gamma}/uv.lock
cat > MODULE.bazel <<EOF
module(name = "project_toml_test")
bazel_dep(name = "aspect_rules_py")
local_path_override(module_name = "aspect_rules_py", path = "$rules_py")
include("//multi-project-hub:setup.MODULE.bazel")
uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
uv.override_package(lock = "@beta_toml//:uv-lock.json", name = "cowsay", testonly = True)
use_repo(uv, "project__beta", "project__gamma")
EOF

check_versions() {
    local package=private/distributions/cowsay
    local beta="@project__beta//$package" gamma="@project__gamma//$package"
    # Read the resolved component versions and check the public beta-only override.
    run_bazel query --repo_contents_cache= --experimental_workspace_rules_log_file="$scratch/conversions" \
        "filter(':_scc__cowsay__', $beta:* + $gamma:*) + attr(testonly, 1, set(@project__beta//:cowsay @project__gamma//:cowsay))" |
        sort |
        diff -u <(printf '%s\n' "@project__beta//:cowsay" "$beta:_scc__cowsay__$1" "$gamma:_scc__cowsay__$2") -

    # The repository-rule log records each converter input. A change to one
    # project must leave the other project's TOML conversion cached.
    shift 2
    grep -aoE '/(beta|gamma)/uv[.]lock' "$scratch/conversions" |
        sort |
        diff -u <(printf '/%s/uv.lock\n' "$@") -
}

pin_cowsay_6_0() {
    # Reuse the wheel-backed 6.0 lock from the existing patch fixture.
    sed -e "s/patching/$1/g" -e 's/, specifier = "==6.0"//' \
        "$case_dir/../uv-patching-829/uv.lock" > "multi-project-hub/$1/uv.lock"
}

check_versions 6_1 6_1 beta gamma
pin_cowsay_6_0 beta
check_versions 6_0 6_1 beta
pin_cowsay_6_0 gamma
check_versions 6_0 6_0 gamma
