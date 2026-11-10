#!/usr/bin/env bash
# Restoring a hub must support both build-option parsing and package loading
# before any independently cached backing repositories have been fetched.
set -euo pipefail

cd "$(dirname "$0")/.."
bazel="${BAZEL:-bazel}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

for phase in seed restore; do
    "$bazel" --batch --output_base="$scratch/$phase" cquery \
        --repo_contents_cache="$scratch/contents" \
        --@pypi_single//dep_group=single_project_hub \
        --output=files '@pypi_single//cowsay:whl' > "$scratch/$phase.files"
done
grep -q '\.whl$' "$scratch/restore.files"
cmp "$scratch/seed.files" "$scratch/restore.files"

# A remote repository cache can restore these repos separately. Following a
# filesystem symlink into another generated repo would bypass Bazel's fetch.
external="$scratch/restore/external"
for file in \
    "$external"/*+uv+pypi_single/{BUILD.bazel,dep_group/BUILD.bazel,cowsay/BUILD.bazel} \
    "$external"/*+uv+project__single_project_hub/private/distributions/cowsay/BUILD.bazel; do
    if [[ ! -f "$file" || -L "$file" ]]; then
        echo "Expected a self-contained generated BUILD file: $file" >&2
        exit 1
    fi
done
