# `rules_py` Downstream Fixes

This document explains the 26 downstream patches we currently carry on top of `rules_py` commit `a20bbd5c2b098a09656b458c7476d2c5478b9f80`.

The intended audience is `rules_py` maintainers who do not know anything about the OpenAI monorepo. The examples below are generic. When a patch is specific to how we consume `rules_py` rather than a general `rules_py` bug, that is called out explicitly.

The numbering matches both:

- the vendored patch files under `project/bazel/vendor_imports/bazel/aspect_rules_py_00NN_*.patch`
- the 26 rebased commits we carry in `~/rules_py`

## `0001` `fix(py): resolve path-like env vars in launchers`

Patch: `aspect_rules_py_0001_fix_py_resolve_path_like_env_vars_in_launchers.patch`

Problem: `py_binary` and `py_test` launchers did not reliably turn user-provided path-like environment variables into real runtime paths.

Why it happened: the launcher already knew how to set some built-in Bazel-related environment variables, but user `env` entries were not processed the same way. If a caller passed a runfiles-relative path, or something that only became meaningful from the launcher working directory, Python saw the raw string instead of an absolute path.

Why this fixes it: the launcher now exports user `env` entries itself and resolves path-like values before starting Python. That makes launcher behavior consistent for both built-in and user-supplied environment variables.

Illustrative example: if a target sets `env = {"CERT_FILE": "my_pkg/certs/ca.pem"}`, the launched process now receives the real file path in the runfiles tree instead of a brittle relative string.

## `0002` `build(rust): use repo-local rust defs for py tools`

Patch: `aspect_rules_py_0002_fix_rust_route_rules_py_tooling_through_rules_rs.patch`

Scope: downstream integration patch.

Problem: the shared Rust library behind the Python tooling was the one remaining outlier that bypassed the repository's Rust wrapper macros.

Why it happened: `py/tools/py/BUILD.bazel` loaded `@rules_rust//rust:defs.bzl` directly while sibling Rust targets already loaded the repo-local wrapper in `//bazel/rust:defs.bzl`. That split made the Python tooling sensitive to whether a consumer needed wrapper-specific defaults, compatibility settings, or repository-local indirection.

Why this fixes it: the patch switches that target to the same wrapper used by the rest of the repository. That keeps the Python tools on the same Rust macro path as the binaries that depend on them.

Illustrative example: a downstream consumer that centralizes Rust toolchain wiring in its own wrapper gets one consistent path for all `rules_py` Rust targets instead of "most targets go through the wrapper, but `py/tools/py` does not."

## `0003` `fix(uv): seed build helper PATH from the Python toolchain`

Patch: `aspect_rules_py_0003_fix_uv_seed_build_helper_path_from_the_python_toolchain.patch`

Problem: sdist builds could fail when the backend tried to invoke `python`, `pip`, or another console script from the build environment.

Why it happened: the sdist build helper reconstructed the environment and accidentally dropped a useful `PATH`. That meant backend subprocesses could lose access to the same virtualenv or interpreter that launched the build.

Why this fixes it: the helper now rebuilds `PATH` starting with the directory containing `sys.executable`. Subprocesses therefore resolve tools from the same Python environment that started the build.

Illustrative example: if the helper is running inside `.../build_venv/bin/python`, a backend that shells out to `maturin` or `pip` now finds `.../build_venv/bin/maturin` or `.../build_venv/bin/pip` first.

## `0004` `fix(uv): wrap sdist compilers to strip unsupported debug flags`

Patch: `aspect_rules_py_0004_fix_uv_wrap_sdist_compilers_to_strip_unsupported_debug_flags.patch`

Problem: native sdist builds could fail because inherited compiler commands contained unsupported flags.

Why it happened: compiler-related environment variables such as `CC`, `CXX`, and `LDSHARED` can already contain wrapper commands and flags from the outer Bazel environment. In our failures, one of those inherited commands included `-fdebug-default-version=4`, which some compilers rejected.

Why this fixes it: instead of trying to rewrite every build backend, the helper inserts tiny compiler wrappers that strip the known-bad flag while preserving the original compiler binary and all other arguments.

Illustrative example: if `CC` is `clang --target=... -fdebug-default-version=4`, the build now runs the same command minus the unsupported flag, so the extension still compiles instead of failing immediately.

## `0005` `fix(uv): suppress successful sdist build output`

Patch: `aspect_rules_py_0005_fix_uv_suppress_successful_sdist_build_output.patch`

Problem: successful sdist builds produced large amounts of log spam.

Why it happened: the helper streamed backend stdout and stderr directly to the terminal even when the build succeeded. That made normal operation noisy and made real failures harder to spot.

Why this fixes it: the helper now captures build output and only replays it when the build fails. Success remains quiet; failure still preserves the diagnostics needed for debugging.

Illustrative example: a package that prints pages of compiler chatter during a successful wheel build no longer floods every Bazel action log.

## `0006` `fix(module): promote source-tool dependencies out of dev-only scope`

Patch: `aspect_rules_py_0006_fix_module_promote_source_tool_dependencies_out_of_dev_only_scope.patch`

Problem: downstream consumers could fail to build `rules_py` tools from source because some required module dependencies were marked as development-only.

Why it happened: `rules_rust`, `rules_rs`, `bzip2`, `xz`, `zstd`, and the `crate` extension lived under the dev-only section of `MODULE.bazel`. That is fine for repository development, but not for real consumers if a source-built tool path is part of normal use.

Why this fixes it: the patch promotes those dependencies into normal module scope so downstream module consumers can resolve them.

Illustrative example: a consumer that needs to compile a Rust-based helper from source can now resolve `@crates` and the native compression libraries instead of failing because those repos only existed in a dev configuration.

## `0007` `fix(uv): recognize generic linux wheel platform tags`

Patch: `aspect_rules_py_0007_fix_uv_recognize_generic_linux_wheel_platform_tags.patch`

Problem: wheels tagged with generic `linux_*` platform tags were filtered out as if they were unsupported.

Why it happened: the platform matching logic recognized `manylinux_*`, `musllinux_*`, and macOS tags, but not plain `linux_x86_64`, `linux_aarch64`, and similar tags. Some publishers do ship those generic Linux wheel tags.

Why this fixes it: the patch teaches the platform filter and config-setting generation to accept generic Linux tags and to normalize a few additional Linux architecture spellings.

Illustrative example: a wheel published as `pkg-1.0.0-cp312-cp312-linux_x86_64.whl` is now considered installable instead of being discarded before platform selection.

## `0008` `fix(uv): normalize architecture aliases during marker evaluation`

Patch: `aspect_rules_py_0008_fix_uv_normalize_architecture_aliases_during_marker_evaluation.patch`

Problem: valid dependencies could be dropped when a PEP 508 marker used one spelling of an architecture name and the platform model used another.

Why it happened: marker evaluation compared `platform_machine` strings literally. That means pairs such as `arm64` and `aarch64`, or `amd64` and `x86_64`, did not match even though they describe the same architecture.

Why this fixes it: the evaluator now normalizes the common aliases before comparing them.

Illustrative example: a dependency guarded by `platform_machine == "arm64"` is now selected correctly on a platform whose canonical machine string is `aarch64`.

## `0009` `fix(uv): preserve nested marker parse state`

Patch: `aspect_rules_py_0009_fix_uv_preserve_nested_marker_parse_state.patch`

Problem: nested PEP 508 marker expressions could be attached to the wrong parenthesized subexpression, producing incorrect evaluation or an invalid intermediate parse tree.

Why it happened: the parser maintained a stack of open subexpressions but appended tokens to the wrong frame in some nested cases. One fallback path also treated a plain list as if it had a custom append helper.

Why this fixes it: the parser now always appends into the innermost active frame and uses normal list append semantics, so nested groups stay properly nested until their matching `)`.

Illustrative example: in `a and (b or (c and d))`, the inner `(c and d)` group now stays isolated inside the larger expression instead of bleeding into the wrong level.

## `0010` `fix(uv): treat abi3 wheels as compatible with newer cpython minors`

Patch: `aspect_rules_py_0010_fix_uv_treat_abi3_wheels_as_compatible_with_newer_cpython_minors.patch`

Problem: `abi3` wheels were treated as matching only the literal CPython version named in the wheel tag.

Why it happened: wheel-selection logic generated select arms directly from the filename tags. For an `abi3` wheel like `cp38-abi3`, that produced only the `cp38` arm even though `abi3` means the wheel should also work on newer CPython minors in the same major series.

Why this fixes it: the patch expands `abi3` compatibility across the supported newer Python minors.

Illustrative example: `pkg-1.0.0-cp38-abi3-manylinux_x86_64.whl` can now satisfy Python 3.9, 3.10, 3.11, and 3.12 instead of looking usable only for Python 3.8.

## `0011` `fix(uv): always keep sdist fallbacks when sources exist`

Patch: `aspect_rules_py_0011_fix_uv_always_keep_sdist_fallbacks_when_sources_exist.patch`

Problem: some packages lost their source-build fallback even though the lockfile included an sdist.

Why it happened: the logic assumed a universal `-none-any` wheel made the sdist unnecessary and elided the source build target. In practice, the presence of a universal wheel does not guarantee that consumers never need the sdist path.

Why this fixes it: whenever an sdist is present, the patch keeps the sdist fallback available.

Illustrative example: if a package has both an sdist and a universal wheel, consumers still have a defined path to source-build it if the wheel cannot be used or needs to be bypassed.

## `0012` `fix(uv): deduplicate merged dependency edge markers`

Patch: `aspect_rules_py_0012_fix_uv_deduplicate_merged_dependency_edge_markers.patch`

Problem: when multiple dependency edges collapsed onto the same normalized dependency, some marker conditions were overwritten.

Why it happened: after extra activation or normalization, two different edges could refer to the same base dependency. The merge logic assigned one marker map over the other instead of unioning them.

Why this fixes it: the patch merges marker sets instead of replacing them, so all relevant conditions survive and duplicate conditions are naturally deduplicated.

Illustrative example: if `foo` depends on `bar` unconditionally and `foo[extra]` also depends on `bar` under a platform-specific marker, both conditions now remain attached to `bar`.

## `0013` `fix(uv): include root-requested extras in dependency graphs`

Patch: `aspect_rules_py_0013_fix_uv_include_root_requested_extras_in_dependency_graphs.patch`

Problem: dependencies implied by extras requested at the root of the lockfile were missing from the generated dependency graph.

Why it happened: graph construction looked at package dependencies and optional dependencies, but not at the root manifest overrides that record requests such as `foo[sqlite]`.

Why this fixes it: the patch reads those root-requested extras and injects the corresponding optional-dependency edges onto the base package, combining the root marker with the dependency's own marker.

Illustrative example: if the root requests `fastapi[standard]`, the dependencies enabled by the `standard` extra now appear in the graph instead of silently disappearing.

## `0014` `fix(uv): add explicit default targets to wheel select chains`

Patch: `aspect_rules_py_0014_fix_uv_add_explicit_default_targets_to_wheel_select_chains.patch`

Problem: generated wheel-selection chains could end without any valid default branch.

Why it happened: the select chain only threaded explicit matching arms, and a default fallback target was only added in some cases. A wheel set with no matching arm and no sdist fallback therefore produced an invalid final selection.

Why this fixes it: the patch gives the chain an explicit `default_target` and synthesizes an incompatible `:whl_missing` target when no real fallback exists. The select graph is therefore always well-formed.

Illustrative example: a Windows-only wheel analyzed on Linux now resolves to a defined incompatible target instead of exploding because the generated `select()` had no usable terminal arm.

## `0015` `fix(py): prefer workspace imports ahead of vendored wheels`

Patch: `aspect_rules_py_0015_fix_py_prefer_workspace_imports_ahead_of_vendored_wheels.patch`

Problem: a workspace package could be shadowed by a third-party wheel that happened to ship the same top-level import.

Why it happened: workspace import roots were emitted as ordinary `.pth` paths. Those are processed too late to beat entries already present in `site-packages`.

Why this fixes it: the patch writes executable `.pth` entries that actively insert workspace paths at the front of `sys.path`, ahead of vendored third-party packages.

Illustrative example: if the workspace contains its own `google/` package and a transitive wheel also provides `google/`, the workspace copy now wins consistently.

## `0016` `fix(py): decode escaped wheel filenames in unpack`

Patch: `aspect_rules_py_0016_fix_py_decode_escaped_wheel_filenames_in_unpack.patch`

Problem: wheel unpacking could fail when the wheel filename on disk was percent-escaped.

Why it happened: the unpacker parsed the raw filename directly. Filenames that contained encoded sequences such as `%2B` were therefore interpreted literally instead of as the wheel name they represent.

Why this fixes it: the patch percent-decodes the filename before parsing it as a wheel filename.

Illustrative example: `pkg-1.0.0%2Blocal-py3-none-any.whl` is now treated as `pkg-1.0.0+local-py3-none-any.whl`, which is the form the parser expects.

## `0017` `build(rust): use repo-local rust defs for runfiles`

Patch: `aspect_rules_py_0017_build_rust_use_repo_local_rust_defs_for_runfiles.patch`

Scope: downstream integration patch.

Problem: the Rust target for the runfiles helper still bypassed the repository's Rust wrapper macros.

Why it happened: `py/tools/runfiles/BUILD.bazel` still loaded `@rules_rust//rust:defs.bzl` directly even after other Rust targets had moved behind the repo-local wrapper.

Why this fixes it: the runfiles helper now uses the same wrapper macro path as the rest of the repository, which keeps Rust defaults and indirection centralized.

Illustrative example: a consumer that changes toolchain behavior in its Rust wrapper no longer gets one behavior for `runfiles` and a different behavior for the rest of the Rust targets.

## `0018` `fix(sdist): fall back to setup.py for incomplete metadata`

Patch: `aspect_rules_py_0018_fix_sdist_fall_back_to_setup_py_for_incomplete_metadata.patch`

Problem: some setuptools-backed sdists with both `pyproject.toml` and `setup.py` built incorrectly when forced through the generic PEP 517 path.

Why it happened: the presence of `pyproject.toml` was treated as a strong signal to use `python -m build`. That is too aggressive for projects that still keep important dependency, extension, or build metadata in `setup.py` or `setup.cfg`.

Why this fixes it: the helper detects setuptools-backed projects that still have `setup.py` and prefers `setup.py bdist_wheel`. For especially suspicious cases, it warns when `pyproject.toml` appears to omit metadata that is still likely coming from legacy setuptools files.

Illustrative example: a package whose `install_requires` or extension configuration still lives in `setup.py` now builds the way the package author intended instead of producing an incomplete wheel.

## `0019` `fix(uv): preserve wheel metadata and expose dist_info`

Patch: `aspect_rules_py_0019_fix_uv_preserve_wheel_metadata_and_expose_dist_info.patch`

Problem: the UV integration exposed installed code but not first-class wheel metadata, which broke metadata-dependent consumers.

Why it happened: the model focused on install trees and package aliases, but did not provide a real `dist-info` target with wheel metadata such as `METADATA` and `entry_points.txt`. Some repository naming and alias plumbing was also too brittle for real lockfiles.

Why this fixes it: the patch adds a real `whl_dist_info` extraction path, threads `dist_info` through `whl_install`, `uv_project`, and `uv_hub`, and makes the generated aliases and exports point to the correct install and metadata targets.

Illustrative example: if a consumer needs `entry_points.txt` to generate a console-script wrapper, it can now depend on the package's `dist_info` instead of discovering that the metadata never made it into the generated repo.

## `0020` `fix(uv): flush marker identifiers before parentheses`

Patch: `aspect_rules_py_0020_fix_uv_flush_marker_identifiers_before_parentheses.patch`

Problem: otherwise-valid marker expressions could tokenize incorrectly when a parenthesis immediately followed an identifier or operator.

Why it happened: the tokenizer handled `(` and `)` before flushing the current buffered token. A sequence such as `and(` could therefore lose the `and` token or attach tokens in the wrong order.

Why this fixes it: the patch flushes any pending identifier or operator token before processing the parenthesis token.

Illustrative example: `sys_platform == "linux" and(platform_machine == "x86_64")` now tokenizes as `and` followed by `(` instead of collapsing into an invalid token sequence.

## `0021` `build: treat archive override as release module`

Patch: `aspect_rules_py_0021_build_treat_archive_as_release_module.patch`

Scope: downstream consumption patch.

Problem: consuming `rules_py` via a raw `archive_override` behaved like a development checkout instead of like the published release module.

Why it happened: `IS_RELEASE` is normally flipped during the release-publishing flow. A raw GitHub archive override bypasses that step, so release-gated logic still thought it was in a development checkout.

Why this fixes it: the patch sets `IS_RELEASE = True` in the archive-consumed copy, which makes module logic follow the release path rather than the development path.

Illustrative example: a consumer using `archive_override` now sees the same dependency and toolchain behavior that it would have seen from the published module, instead of unexpectedly getting dev-only module wiring.

## `0022` `fix(sdist): discover Bazel embedded JDK`

Patch: `aspect_rules_py_0022_fix_sdist_discover_bazel_embedded_jdk.patch`

Problem: sdists that need Java or JNI headers could fail because the build environment had no usable `JAVA_HOME`.

Why it happened: the helper prepared compiler wrappers and Python environment details, but if `JAVA_HOME` was unset it never looked for Bazel's embedded JDK or nearby installed Java binaries.

Why this fixes it: the patch discovers Java from `JAVA_HOME`, `java`/`javac` on `PATH`, and nearby Bazel embedded JDK locations, then exports the result as `JAVA_HOME` for the build.

Illustrative example: a package with JNI bindings can now find headers and the Java runtime even when the outer environment did not define `JAVA_HOME`.

## `0023` `fix(uv): thread package annotations into wheel installs`

Patch: `aspect_rules_py_0023_fix_uv_thread_package_annotations_into_wheel_installs.patch`

Problem: package annotations were only partially honored for wheel installs. Build dependencies might flow through, but wheel patches, extra data, patch strip settings, and additive BUILD content could be lost.

Why it happened: annotation handling focused primarily on source-build dependencies. The wheel-install repository and its generated BUILD logic did not carry the full annotation record or apply wheel-side modifications.

Why this fixes it: the patch upgrades annotations to a fuller package record, threads them through the UV extension, teaches `whl_install` to apply wheel patches during unpack, and merges annotation-provided data and additive BUILD content into the generated package.

Illustrative example: if a package needs a small patch to one installed Python file and also needs a runtime data file in runfiles, both modifications now survive the wheel-install path instead of only the source-build path.

## `0024` `fix(uv): merge version-split scc dependency markers`

Patch: `aspect_rules_py_0024_fix_uv_merge_version_split_scc_dependency_markers.patch`

Problem: marker conditions could be dropped when the same surface dependency appeared through multiple lockfile versions inside a strongly connected component (SCC).

Why it happened: SCC dependency processing first keyed entries by the full versioned dependency, but later collapsed them to just the package name. When that collapse happened, later entries overwrote earlier marker sets instead of merging them.

Why this fixes it: the patch merges all marker sets across the versioned entries before collapsing them to the final surface package key.

Illustrative example: if one Python range needs `pyarrow 18` and another needs `pyarrow 19`, the final `pyarrow` edge now retains both marker branches instead of only whichever version happened to be processed last.

## `0025` `fix(rust): namespace internal crates repo`

Patch: `aspect_rules_py_0025_fix_rust_namespace_internal_crates_repo.patch`

Problem: `rules_py`'s private Rust tool dependencies used the generic repo name `@crates`, which collides easily with a consumer's own Rust crate hub.

Why it happened: the internal helper binaries (`py`, `venv_bin`, `unpack_bin`, `venv_shim`) depended on a repo generated by `crate.from_cargo(name = "crates", ...)`. In a large Bzlmod graph, `@crates` is a common name, and consumers can already have their own unrelated `@crates` repo. Once that happens, the private `rules_py` tool targets can accidentally resolve against the consumer's crate hub instead of their own.

Why this fixes it: the patch renames the internal repo to `@rules_py_crates` and updates the Rust tool targets to depend on that namespaced repo. That makes the repo identity specific to `rules_py` instead of relying on a globally generic name.

Illustrative example: if a monorepo already has `@crates` for its own Cargo workspace, `rules_py`'s internal tool crates no longer collide with it. The internal tools now always resolve their Rust deps from `@rules_py_crates`.

## `0026` `fix(rust): retarget crate annotations after repo rename`

Patch: `aspect_rules_py_0026_fix_rust_retarget_crate_annotations_after_repo_rename.patch`

Problem: after renaming the internal crate repo, the `crate.annotation(...)` entries in `MODULE.bazel` still pointed at the old repo name.

Why it happened: the repo rename changed the generated crate hub name, but the annotation blocks still declared `repositories = ["crates"]`.

Why this fixes it: the patch updates those annotation blocks to target `rules_py_crates`, so crate-specific overrides still apply to the renamed internal repo.

Illustrative example: if `rules_py` disables a build script or adds native deps for an internal Rust crate such as `zstd-sys`, that override now still lands on the correct generated repo after the rename.
