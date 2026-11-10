# OpenAI rules_py fork

This fork applies all 44 active downstream rules_py patches, in their registered order, to upstream [`64ac812ee41b`](https://github.com/aspect-build/rules_py/commit/64ac812ee41bd7e3becec4ca1efa2a14e5337614). Upstream history is retained. Each patch is a separate commit with its purpose and original patch SHA-256 in the commit message.

The module name remains `aspect_rules_py`. This snapshot includes the aspect-based runfiles-group integration, indexed imports, shared bytecode and wheel metadata, native source-build fixes, and incremental uv dependency repositories. It does not bundle the separate rules_img or rules_runfiles_group patch stacks.

## Using this fork

Pin an immutable commit archive from `zbarsky-openai/rules_py` with your root module's `archive_override`. Replace the upstream archive pin and remove the corresponding 44 local rules_py patches, since their changes are already applied here.

The producer describers require the unreleased rules_runfiles_group aspect API. The fork pins that API for its own development builds. Bzlmod ignores overrides in dependency modules, so a consuming root must also provide this override (or an equivalent compatible pin):

```starlark
bazel_dep(name = "rules_runfiles_group", version = "0.1.0")
archive_override(
    module_name = "rules_runfiles_group",
    integrity = "sha256-F0N7t2ns7z1rFDM6H4LUbwcD6etkUghCijrwh1559tc=",
    strip_prefix = "rules_runfiles_group-d105dfab75fb550bcfc0d2cc033b27fad0dfc2e4",
    urls = ["https://github.com/bazel-contrib/rules_runfiles_group/archive/d105dfab75fb550bcfc0d2cc033b27fad0dfc2e4.tar.gz"],
)
```

Consumers that already patch rules_runfiles_group or rules_img should retain those separate overrides. The pin above supplies the Python producer API; it does not replace consumer-specific grouping or image-packaging changes.

## Fork integration updates

The commits after the imported stack pin the unreleased aspect API for development, refresh the module lockfile, and adapt the retained `py_image_layer` consumer to the shared `wheels_depset` helper. The migration no longer calls that legacy consumer, but this fork still exports it, so its wheel-provider access must follow the same contract as virtualenv and PEX consumers.

## Validation

The import was checked byte for byte against the downstream Bazel-patched tree: all 1,563 distributed source files matched before the documented fork integration updates. The 124 example files excluded by upstream's archive attributes remain in Git.

On Linux x86-64, 71 distinct Bazel test targets passed: 60 upstream dependency/namespace analysis tests, six consumer runfiles/image tests, and these five standalone targets using the repository's Bazel 8.6 configuration:

```sh
bazel test \
  //uv/private/pep517_whl/tests:build_helper_test \
  //uv/private/pep517_whl/tests:memory_monitor_test \
  //py/tests/image-layer-compression:merged_pip_test \
  //py/tests/image-layer-compression:solo_pip_test \
  //py/tests/image-layer-compression:merged_pip_targets_test
```

The native helper targets also passed under Bazel 10. The same Python helper suites passed 95 direct unit tests under Python 3.12. The legacy merged-wheel test reproduced the removed-provider-field error before the two-line adaptation and passed afterward. Module metadata was regenerated with `bazel mod tidy` and checked for stable output.

This is focused Linux validation, not a completed upstream CI or cross-platform matrix run.

## Patch inventory

[Machine-readable inventory](openai-patches.json) records the ordered patch names, original patch hashes, and resulting commits. The explanations below describe the imported changes.

| # | Patch | Purpose |
| --- | --- | --- |
| 1 | [allow_sha_release_ids](https://github.com/zbarsky-openai/rules_py/commit/5abe12b413a6782294c4f2bd86367b8ac7c492b2) | Allow a 40-character lowercase hexadecimal release identifier alongside dated Python standalone builds. This permits immutable custom interpreter releases without weakening validation of either format. |
| 2 | [composable_test_rule](https://github.com/zbarsky-openai/rules_py/commit/cfe54c530d268500a00ea3181a25c012195d3c7c) | Export the underlying test rule and let py_test accept a replacement rule. Downstream macros can compose test behavior while retaining the shared virtualenv construction. |
| 3 | [default_wheel_exclusions](https://github.com/zbarsky-openai/rules_py/commit/bb272f3e0a07586412c7dde185fc7a4c5c1c586d) | Merge project defaults with package-specific exclusion patterns, with package selection and opt-out controls. This avoids repeating common wheel trimming policy on every package while preserving exceptions. |
| 4 | [deterministic_wheel_install](https://github.com/zbarsky-openai/rules_py/commit/80c7fb8d983c080727c611dfadd026d1851f76be) | Set PYTHONHASHSEED=0 for the wheel installation action so hash-dependent compiler output does not vary across identical builds. |
| 5 | [freethreaded_stripped](https://github.com/zbarsky-openai/rules_py/commit/d3377327db067e8bdff7af9e2b21839064fafaa5) | Respect install_only_stripped for free-threaded Python releases. Selecting the stripped archive avoids carrying unnecessary debug sections into deployed runtimes and profilers. |
| 6 | [hermetic_native_linker](https://github.com/zbarsky-openai/rules_py/commit/2bb24923bb6e71a3bdb13aa782bb700968aadd6a) | Select the toolchain linker for native wheel builds, expose sibling archiver tools on PATH, and preserve LDSHARED. This keeps source builds from accidentally selecting host linker tools. |
| 7 | [indexed_imports](https://github.com/zbarsky-openai/rules_py/commit/bbb92ccbc5369679d3d6171553bbcdf041e7c764) | Build an import index for eligible wheel contents and install a runtime resolver instead of projecting every import path into every virtualenv. Preserve namespace, metadata, entrypoint, and collision semantics while reducing repeated analysis and filesystem work. |
| 8 | [pre_build_patches_force_source](https://github.com/zbarsky-openai/rules_py/commit/733326e065579b54ae73a75ad277cd92b3f76df5) | Treat pre_build_patches as a source-build requirement and fail clearly if the lockfile has no source archive. Otherwise a selected binary wheel can silently bypass the requested patch. |
| 9 | [registered_versions](https://github.com/zbarsky-openai/rules_py/commit/0101d78de77c1d1e922919e8050bcdfa7744e4ef) | Write the sorted registered Python versions to a public versions.bzl file. Consumers can derive their configuration from the actual interpreter registration instead of maintaining a second version list. |
| 10 | [native_wheel_sysroot](https://github.com/zbarsky-openai/rules_py/commit/44ae4a746bdc708115cccce8b10ef885ae58d1b1) | Carry the selected C++ toolchain sysroot into native wheel build environments and compiler wrappers. This keeps cross-builds on the configured target headers and libraries. |
| 11 | [native_wheel_llvm_compile_flags](https://github.com/zbarsky-openai/rules_py/commit/8dfe65c1b975865e7822f819c482251fe021802d) | Use the C++ toolchain action configurations to supply C, C++, shared-link, and executable-link flags to source builds. Native wheels need the same target configuration as ordinary Bazel C++ actions. |
| 12 | [native_wheel_link_inputs](https://github.com/zbarsky-openai/rules_py/commit/e11bfd846a77574745768f7824680b809b18f279) | Distinguish compiler queries, compilation, and linking, including response-file arguments. Supply native link inputs only to link invocations so backend probes and compile-only commands remain valid. |
| 13 | [native_wheel_windows_platform](https://github.com/zbarsky-openai/rules_py/commit/e41d82e34aa61ac7a4380f1c10f53e0e43d9839f) | Map Windows target constraints into the wheel build platform configuration. Cross-build metadata must describe the selected target instead of falling back to another operating system. |
| 14 | [global_target_overrides](https://github.com/zbarsky-openai/rules_py/commit/d1e0fb396dc7b5a8cdff2beb35da6d60cffeab4b) | Allow target replacements and annotation files to apply across all project locks in a module. This centralizes shared package policy while retaining explicit lock scoping when needed. |
| 15 | [required_runfiles](https://github.com/zbarsky-openai/rules_py/commit/4ab95935938653ef603f2b9ab1866db843c5736c) | Use the tar rule default runfiles handling for the native dependency source fixture. This keeps the fixture compatible with the runfiles packaging contract. |
| 16 | [unpacked_wheel_runtime_paths](https://github.com/zbarsky-openai/rules_py/commit/c4171ecaee421b6e81a387fe3fd75817f18b7169) | Include the Python major/minor version and free-threaded suffix in unpacked wheel directories. Runfiles paths omit configuration identifiers, so different interpreter variants otherwise collide. |
| 17 | [first_party_precompile](https://github.com/zbarsky-openai/rules_py/commit/28356a49e2f35db5f4aeb6dfe694135673347dda) | Add controlled first-party precompilation and its virtualenv mapping. Consumers can include deterministic bytecode alongside source without changing the default source ownership model. |
| 18 | [shared_first_party_precompile](https://github.com/zbarsky-openai/rules_py/commit/570ea748a1e3e1a9a3756947b770ff30ebc19f2c) | Collect compilation outputs through producer metadata and reuse them in consuming virtualenvs. This avoids recompiling the same library for every binary while preserving the source-to-bytecode mapping. |
| 19 | [wheel_record_fields](https://github.com/zbarsky-openai/rules_py/commit/676f179c8fab5bad13557705080786d29d3b49d5) | Represent wheel records and their claims with fixed-field providers. These records are numerous and shared throughout analysis; explicit fields reduce the cost of carrying their metadata. |
| 20 | [shared_wheel_projection_records](https://github.com/zbarsky-openai/rules_py/commit/ba172c04ec959bdc21c78d2885bb25abab1d7c85) | Compute each wheel entry projection once at its producer and share records through postorder depsets. This avoids rebuilding equivalent records in every virtualenv while retaining collision precedence and PEX consumers. |
| 21 | [shared_console_scripts](https://github.com/zbarsky-openai/rules_py/commit/7c69c91722d5a6d69ab2c48ecb389bcd0e521204) | Render console-script content once per wheel and reuse it in lightweight write actions. Enable console scripts by default so subprocess users retain the wrappers, with an explicit opt-out. |
| 22 | [private_venv_name](https://github.com/zbarsky-openai/rules_py/commit/b64d1794e82db420c844a8a647cc295514c0f76e) | Let macro callers choose the private virtualenv target name. Symbolic macros require generated target names to share the macro prefix, even when the virtualenv stays private. |
| 23 | [typecheck_wheel_paths](https://github.com/zbarsky-openai/rules_py/commit/8450f355f797f575126fe77149effc4fa148fa25) | Provide type-checking paths for wheel-backed imports alongside indexed runtime imports. Static tools need concrete source paths even when runtime imports use the compact index. |
| 24 | [projection_iteration](https://github.com/zbarsky-openai/rules_py/commit/444bff47605017fb09b5b94d15e0301fd92b2d0f) | Iterate projection dictionaries by key and defer removals until traversal completes. This avoids repeated items() allocations without mutating an active dictionary iterator. |
| 25 | [reproducible_sdist_configure](https://github.com/zbarsky-openai/rules_py/commit/c26ca83b5f440e62b8d69c09bb89ce8902ae509a) | Track interpreter archive identity and source archive inputs, then run the bundled inspection tool in isolated mode. Mark only successful inspections without setup.py as reproducible; custom or host-dependent configuration stays uncached. |
| 26 | [replacement_deps](https://github.com/zbarsky-openai/rules_py/commit/58cd27469a2075731e749d22acf33ee624c4e9cc) | Carry replacement targets and their dependency metadata through project and build dependency generation. Replacing a package must not silently discard the dependency closure needed by its consumers. |
| 27 | [sdist_build_tool](https://github.com/zbarsky-openai/rules_py/commit/adc361b0b40c0eb4a45cf9591f400d10fa7e633d) | Allow an explicit build tool to flow through source-build configuration and the PEP 517 helper. Build backends can use a declared tool and its inputs instead of relying on ambient executables. |
| 28 | [native_wheel_debug_prefix_map](https://github.com/zbarsky-openai/rules_py/commit/dde56800554233dcb399fe9091e9d15b936e6ad8) | Apply debug-prefix maps to both cross compiler drivers, including combined compile-and-link commands and response files. Preserve debug information without embedding sandbox or interpreter repository paths. |
| 29 | [selective_sdist_metadata](https://github.com/zbarsky-openai/rules_py/commit/69681a7267a094504b140eb1789537ea4e8c9aad) | Generate and load the build dependency metadata needed by each source build. This reduces repeated metadata work while keeping dependency selection explicit. |
| 30 | [runtime_runfiles](https://github.com/zbarsky-openai/rules_py/commit/03f533c0a4e70ec529f4654e39b13e606373b994) | Include library sources in default runfiles and merge the virtualenv runtime after ordinary data runfiles. Packaging sees the full runtime closure and retains the virtualenv-selected files. |
| 31 | [native_wrapper_interpreter](https://github.com/zbarsky-openai/rules_py/commit/7578253c4b0cce77bc2b6a3715d1cff9a46df4da) | Generate compiler wrappers with the PEP 517 frontend interpreter rather than rediscovering Python through PATH. This preserves the interpreter identity and its runtime dependencies. |
| 32 | [cross_host_identity](https://github.com/zbarsky-openai/rules_py/commit/f33b5c35a20167ed3f1fe9b32e44ea435e88a2bf) | Keep the executing interpreter host identity intact and configure target wheel metadata explicitly. Pretending the host process is the target breaks build tools that must execute locally. |
| 33 | [wheel_runtime_namespace](https://github.com/zbarsky-openai/rules_py/commit/e0fdfe5df901200ab54f6ecf27b3dcd09e5d681f) | Separate wheel installation paths by the selected Python runtime and isolate helper subprocess runfiles. Multiple configured runtimes can then coexist without runfiles collisions or inherited launcher state. |
| 34 | [runfiles_groups](https://github.com/zbarsky-openai/rules_py/commit/dc6d646205d5c9ac188aeb711e350dfd8a85781c) | Expose producer-owned source, bytecode, virtualenv, wheel, interpreter, data, and dependency groups through RunfilesGroupInfo. Aspect-based image packagers can retain reusable dependency boundaries and explicit source groups without duplicating rules_py internals or losing runtime files. |
| 35 | [namespace_prefix_scan](https://github.com/zbarsky-openai/rules_py/commit/25c10808ecfdd8ce07e373d5ab6afddd8d597054) | Scan namespace ancestry on component boundaries rather than repeatedly testing unrelated prefixes. This reduces analysis work while preserving the distinction between neighboring package names. |
| 36 | [native_package_overrides](https://github.com/zbarsky-openai/rules_py/commit/4331964fd104b99a7dd141cd2d49664860715bb3) | Expose native replacement targets for single-version runtime dependencies without changing locked dependency edges, version selection, or build-only groups. |
| 37 | [uv_incremental_repositories](https://github.com/zbarsky-openai/rules_py/commit/97e302d129ca6e2468d984c86f5aa634513c659a) | Split generated uv state into per-distribution repositories and per-group dependency modules. Unrelated package and group changes then avoid invalidating a monolithic generated repository. |
| 38 | [uv_incremental_repository_tests](https://github.com/zbarsky-openai/rules_py/commit/ddf47ffa92cb9485d18c4e6f0e39e3d166b411d6) | Update the existing generator fixtures, snapshots, and group API examples, and exercise repository-cache restoration. These checks protect the incremental repository boundaries introduced by the preceding patch. |
| 39 | [reuse_group_sccs](https://github.com/zbarsky-openai/rules_py/commit/c72ad8b1e63a5511eab06f597bbf3caa051c16bb) | Reuse dependency cycle computations for Python groups with identical active edges. Equivalent groups should not repeat the same graph traversal during extension evaluation. |
| 40 | [cache_project_toml](https://github.com/zbarsky-openai/rules_py/commit/7a95df5323c779088a2a7aa7328d0b27f86bc8e1) | Convert each project TOML input once and reuse its annotations. This avoids duplicate converter processes and decoding work during module extension evaluation. |
| 41 | [build_helper_bytecode](https://github.com/zbarsky-openai/rules_py/commit/29826232ea9b9563d1f8d3aeb5d78f2738b2a3ff) | Run import-index, namespace-merge, and first-party compilation helpers from bytecode. This reduces repeated helper startup parsing while preserving their existing inputs and outputs. |
| 42 | [multiversion_wheel_filters](https://github.com/zbarsky-openai/rules_py/commit/8021eb42771300cf73a974485ea9aa53cf07095d) | Apply package wheel exclusions to every matching locked release. A multi-version lock must not leave one release unfiltered because the annotation was associated with another version. |
| 43 | [multiversion_build_tools](https://github.com/zbarsky-openai/rules_py/commit/b051917f44872fe9c08854ce40397e173e49fa9e) | Use build dependency aliases for source-build tools, including tools absent from runtime groups. Build-only dependencies must remain available without adding them to application runtime closures. |
| 44 | [locked_runtime_forks](https://github.com/zbarsky-openai/rules_py/commit/3634a0a98a128376b45e2ce4708832787d40fd6d) | Restrict runtime package and extra activation to the selected uv lock fork. This prevents edges from incompatible marker forks from leaking into the chosen runtime dependency graph. |
