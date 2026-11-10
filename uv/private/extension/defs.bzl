"""A Bazel module extension for resolving Python dependencies from a `uv.lock` file.

This extension provides a mechanism for resolving Python dependencies declared in a
`pyproject.toml` and locked in a `uv.lock` file. It generates a dependency graph,
handles platform-specific constraints, and creates repository rules for fetching
pre-built wheels (bdists) or building wheels from source (sdists).

The extension is designed to handle complex dependency scenarios, including:
- Cross-platform builds for different operating systems and architectures.
- Hermetic builds of source distributions.
- Dependency cycles, which are resolved by computing the strongly connected
  components (SCCs) of the dependency graph.

## Example

The following example shows how to use the `uv` module extension in a `MODULE.bazel`
file:

```starlark
uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
uv.declare_hub(hub_name = "uv")
uv.project(
    hub_name = "uv",
    name = "my_project",
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)
use_repo(uv, "uv")
```

This configuration declares a `uv` hub and registers a project with its
`pyproject.toml` and `uv.lock` files. The `use_repo` directive then makes the
resolved dependencies available in the `@uv` repository.

## Common Types

- **Dependency:** A tuple of `(project_id, package_name, version, extra)` that
  uniquely identifies a package within a lockfile. `project_id` is a unique
  identifier for the lockfile, `package_name` is the normalized name of the
  package, `version` is the package version, and `extra` is the optional extra
  (or `__base__` for the base package).
- **Marker:** A string representing a PEP 508 marker, used to specify
  environment-specific dependencies (e.g.,
  `"sys_platform == 'linux'"`).
- **SCC:** A Strongly Connected Component, which is a set of packages that have
  cyclic dependencies on each other.

## Appendix

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set_values")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/interpreter:resolve.bzl", "resolve_host_interpreter_label")
load("//uv:repositories.bzl", "read_toml_or_json")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/git_archive:repository.bzl", "git_archive")
load("//uv/private/sdist_build:attrs.bzl", "validate_build_attrs")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/uv_hub:repository.bzl", "uv_hub")
load("//uv/private/uv_project:repository.bzl", "declare_project")
load("//uv/private/uv_project:select_gen.bzl", "project_package_label")
load("//uv/private/whl_install:dist_repository.bzl", "whl_dist")
load("//uv/private/whl_install:metadata.bzl", "parse_console_script")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":graph_utils.bzl", "activate_extras", "collect_build_deps", "collect_sccs", "group_activations", "replace_dependencies")
load(":lockfile.bzl", "collect_bdists", "collect_configurations", "collect_sdists", "normalize_lock", "url_basename")
load(":projectfile.bzl", "collect_activated_extras", "extract_requirement_marker_pairs")

# attr.string_dict cannot distinguish omission from an explicitly empty map.
# The empty script name is invalid, so this sentinel cannot collide with a
# valid console-script declaration.
_CONSOLE_SCRIPTS_UNSET = {"": ""}

def merge_exclude_globs(
        default_exclude_glob,
        package_exclude_glob,
        inherit_default_exclude_glob,
        default_applies = True):
    """Merge project and package exclusions without modifying either."""
    patterns = {pattern: True for pattern in default_exclude_glob} if inherit_default_exclude_glob and default_applies else {}
    for pattern in package_exclude_glob:
        patterns[pattern] = True
    return patterns.keys()

def _dist_sha256(dist):
    """The distribution's sha256 for http_file, or None for other hash algorithms."""
    hash = dist.get("hash", "")
    return hash[len("sha256:"):] if hash.startswith("sha256:") else None

def shared_install_key(install_cfg):
    """Order-sensitive identity for a wheel install shareable across lock universes.

    Two lockfiles that pin the same package version resolve to the same
    content-addressed `whl_dist` labels, so their `whl_install` selector repos
    generate byte-identical BUILD files and can collapse to one. Returns None
    for project-local installs (source builds, patches, extra deps/data), whose
    inputs are keyed per-lockfile and never interchangeable.
    """
    if install_cfg.sbuild or install_cfg.post_install_patches or install_cfg.extra_deps or install_cfg.extra_data:
        return None

    # Wheel selection keeps the first candidate on a specificity tie.
    return (tuple(install_cfg.whls.items()), tuple(install_cfg.exclude_glob), install_cfg.testonly)

def dedupe_shared_installs(install_cfgs):
    """Drop duplicate shareable installs, returning `{dropped_id: canonical_id}`.

    Mutates `install_cfgs` in place, keeping the first install of each identity
    as the canonical repo. Callers rewrite references to dropped ids through the
    returned remap so no dangling `@dropped//:install` label survives.
    """
    seen = {}
    id_remap = {}
    for install_id, cfg in install_cfgs.items():
        key = shared_install_key(cfg)
        if key == None:
            continue
        canonical = seen.setdefault(key, install_id)
        if canonical != install_id:
            id_remap[install_id] = canonical
    for dropped in id_remap:
        install_cfgs.pop(dropped)
    return id_remap

def map_scc_installs(scc_graph, install_table):
    """Map SCC members to install labels, merging markers for shared targets.

    Args:
        scc_graph: SCC IDs mapped to member dependencies and marker sets.
        install_table: Dependency tuples mapped to their install labels.

    Returns:
        SCC IDs mapped to install labels and their combined marker sets.
        Members without installs, such as extra pseudo-packages, are omitted.
    """
    mapped = {}
    for scc_id, members in scc_graph.items():
        installs = {}
        for member, markers in members.items():
            if member in install_table:
                installs.setdefault(install_table[member], {}).update(markers)
        mapped[scc_id] = installs
    return mapped

def parse_declared_console_script(name, entry_point):
    """Canonicalize one override_package console-script declaration.

    Args:
        name: Script name installed under the venv's bin directory.
        entry_point: Python entry point encoded as module:object.

    Returns:
        The canonical name=module:object string, or None when invalid.
    """
    whitespace = [" ", "\t", "\n", "\r"]
    if (
        name in ("", ".", "..") or
        "/" in name or
        "\\" in name or
        "=" in name or
        "=" in entry_point or
        "[" in entry_point or
        "]" in entry_point or
        len(entry_point.split(":")) != 2 or
        any([char in name or char in entry_point for char in whitespace])
    ):
        return None
    parsed = parse_console_script("{}={}".format(name, entry_point))
    return parsed[1] if parsed != None else None

def _merge_scc_dep_markers(marked_deps):
    """Merge SCC dep markers, re-keyed from lock tuple to surface package name.

    SCC external deps are keyed by the fully versioned lock tuple, but the
    generated hub targets key on the surface package alias. Merging across all
    versions lets split dependencies (e.g. chdb -> pyarrow) preserve their full
    platform coverage instead of overwriting each other. Absolute replacement
    labels remain unchanged.
    """
    merged = {}
    for dep, markers in marked_deps.items():
        merged.setdefault(dep if type(dep) == "string" else dep[1], {}).update(markers)
    return merged

def _parse_projects(module_ctx, declared_hubs):
    """Resolve every `uv.project()` declaration into repository-rule inputs.

    For each project the `pyproject.toml` and `uv.lock` are decoded, the
    dependency graph and its strongly connected components are computed, and the
    per-package install/build/override configuration is assembled.

    Args:
        module_ctx: The Bazel module context.
        declared_hubs: Hub names declared across all modules.

    Returns:
        A struct of the inputs consumed by `_uv_impl`, with fields:

          - project_cfgs: arguments for declare_project, keyed by project id.
          - hub_cfgs: `{hub_name -> {configurations, packages}}` aggregated
            per-hub configuration/package surface.
          - install_cfgs: `{whl_install key -> install struct}` wiring each
            resolved package to its wheels, optional sbuild and patches.
          - sbuild_cfgs: `{sbuild_id -> sdist_build struct}` for packages that
            may build a wheel from source.
          - whl_cfgs: platform configuration matrix for `configurations_hub`.
          - sdist_cfgs: source download specs keyed by repository name.
          - bdist_cfgs: wheel download specs keyed by wheel label.
    """

    hub_cfgs = {}
    project_cfgs = {}
    wheel_files = {}

    sdist_specs = {}
    sdist_table = {}

    bdist_specs = {}

    sbuild_specs = {}

    install_cfgs = {}
    install_table = {}

    # FIXME: Collect build deps files/annotations
    for mod in module_ctx.modules:
        project_locks = {project.lock: True for project in mod.tags.project}
        for override in mod.tags.override_package:
            if override.lock != None and override.exclude_locks:
                fail("uv.override_package() for '{}': lock and exclude_locks are mutually exclusive".format(override.name))
            for excluded_lock in override.exclude_locks:
                if excluded_lock not in project_locks:
                    fail("uv.override_package() for '{}' excludes unregistered lock '{}'".format(override.name, excluded_lock))
            if override.lock != None and override.lock not in project_locks:
                fail("uv.override_package() for '{}' refers to lock '{}', but module '{}' has no uv.project() for that lock.".format(
                    override.name,
                    override.lock,
                    mod.name,
                ))

            if override.pre_build_patch_strip != 1 and not override.pre_build_patches:
                fail("uv.override_package() for '{}': `pre_build_patch_strip` requires `pre_build_patches`.".format(override.name))
            if override.post_install_patch_strip != 1 and not override.post_install_patches:
                fail("uv.override_package() for '{}': `post_install_patch_strip` requires `post_install_patches`.".format(override.name))

            has_target = override.target != None
            has_modifications = (
                override.testonly or
                override.build_tool or
                override.console_scripts != _CONSOLE_SCRIPTS_UNSET or
                override.pre_build_patches or
                override.post_install_patches or
                override.exclude_glob or
                not override.inherit_default_exclude_glob or
                override.replacement_deps or
                override.extra_deps or
                override.extra_data or
                override.toolchains or
                override.env or
                override.config_settings or
                override.monitor_memory or
                override.resource_set != "default"
            )
            if has_target and has_modifications:
                fail("uv.override_package() for '{}': `target` is mutually exclusive with modification attributes.".format(override.name))
            if not has_target and not has_modifications:
                fail("uv.override_package() for '{}': must specify either `target` for full replacement or at least one modification attribute (build_tool, testonly, console_scripts, pre_build_patches, post_install_patches, exclude_glob, replacement_deps, extra_deps, extra_data, toolchains, env, monitor_memory, resource_set).".format(override.name))

        unscoped_matches = {}

        for project in mod.tags.project:
            default_exclude_packages = {
                normalize_name(name): True
                for name in project.default_exclude_packages
            }
            project_data = read_toml_or_json(module_ctx, project.pyproject)
            lock_data = read_toml_or_json(module_ctx, project.lock)

            # The stamp derives from the project name: stable across reloads and
            # unique within a hub. Repository keys are rebuilt whenever the toml
            # changes, so a human-readable stamp is safe to reuse.
            project_stamp = normalize_name(project_data["project"]["name"])
            project_id = "project__" + project_stamp

            project_name = project.name or project_data["project"]["name"]

            if project.hub_name not in declared_hubs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            no_binary_packages = {
                normalize_name(p): True
                for p in project_data.get("tool", {}).get("uv", {}).get("no-binary-package", [])
            }

            default_versions, package_versions, marker_graph = normalize_lock(project_id, lock_data)

            def _resolve(package):
                name = normalize_name(package["name"])
                if "version" in package:
                    return (project_id, name, package["version"], "__base__")
                return default_versions.get(name)

            lock_build_dep_anns = {}
            lock_native_anns = {}
            for ann in mod.tags.annotate_packages:
                if ann.lock == None or ann.lock == project.lock:
                    annotations = read_toml_or_json(module_ctx, ann.src)
                    for package in annotations.get("package", []):
                        k = _resolve(package)
                        if k == None:
                            # Allow a shared annotation file to include entries for other locks.
                            continue
                        if "native" in package:
                            if type(package["native"]) != "bool":
                                fail("Annotation `native` for package {} in {} must be a boolean, got {}".format(package["name"], ann.src, repr(package["native"])))
                            lock_native_anns[k] = package["native"]
                        if "build-dependencies" in package:
                            deps = []
                            skip = False
                            for dep in package["build-dependencies"]:
                                resolved = _resolve(dep)
                                if resolved == None:
                                    skip = True
                                    break
                                deps.append(resolved)
                            if not skip:
                                lock_build_dep_anns[k] = deps

            package_overrides = {}
            replacement_deps = {}
            package_console_scripts = {}
            testonly_packages = {}
            native_targets = {}
            for i, override in enumerate(mod.tags.override_package):
                if project.lock in override.exclude_locks or (override.lock != None and override.lock != project.lock):
                    continue

                name = normalize_name(override.name)
                available_versions = package_versions.get(name, {})
                if override.lock == None and not available_versions:
                    continue

                v = override.version or default_versions.get(name, (None, None, None, None))[2]
                if not v:
                    fail("Overridden project {} neither specifies a version nor has an implied singular version in lock {}!".format(override.name, project.lock))
                if v not in available_versions:
                    if override.lock == None:
                        continue
                    fail("uv.override_package() for package '{}' selects version '{}', which is absent from lock '{}'; available versions: {}".format(
                        override.name,
                        v,
                        project.lock,
                        sorted(available_versions.keys()),
                    ))

                override_key = (name, v)
                if override_key in package_overrides:
                    fail("Duplicate uv.override_package() for package '{}' version '{}' in lock '{}'. Each (lock, name, version) triple may only be overridden once.".format(
                        override.name,
                        v,
                        project.lock,
                    ))

                if override.lock == None:
                    unscoped_matches[i] = True

                if override.console_scripts != _CONSOLE_SCRIPTS_UNSET:
                    console_scripts = []
                    for raw_script_name, raw_entry_point in sorted(override.console_scripts.items()):
                        console_script = parse_declared_console_script(raw_script_name, raw_entry_point)
                        if console_script == None:
                            fail("uv.override_package() for '{}=={}' in lock '{}': `console_scripts` must map valid script names to `module:object` entry points; got {} = {}".format(
                                override.name,
                                v,
                                project.lock,
                                repr(raw_script_name),
                                repr(raw_entry_point),
                            ))
                        console_scripts.append(console_script)
                    package_console_scripts[override_key] = console_scripts

                package_overrides[override_key] = override
                if override.testonly:
                    testonly_packages[name] = True

                install_key = available_versions[v]
                if override.replacement_deps:
                    replacements = {normalize_name(dep): str(label) for dep, label in override.replacement_deps.items()}
                    if len(replacements) != len(override.replacement_deps):
                        fail("uv.override_package() for '{}=={}' in lock '{}': replacement_deps names must be distinct after normalization.".format(override.name, v, project.lock))
                    replacement_deps[install_key] = replacements
                if override.target != None:
                    if module_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
                        print("Overriding {}@{} in {} with {}".format(override.name, v, project_name, override.target))
                    install_table[install_key] = str(override.target)
                    if override.lock != None and len(available_versions) == 1:
                        native_targets[install_key] = True

            lock_build_deps = None
            lock_build_dep_labels = None

            if replacement_deps:
                # Validate base and extra edges before applying group activations.
                missing = {package[1:3]: dict(replacements) for package, replacements in replacement_deps.items()}
                for parent, deps in marker_graph.items():
                    names = missing.get(parent[1:3])
                    if names:
                        for dep in deps:
                            names.pop(dep[1], None)
                for (name, version), names in missing.items():
                    if names:
                        fail("uv.override_package() for '{}=={}' in lock '{}': replacement_deps names are not direct dependencies: {}".format(
                            name,
                            version,
                            project.lock,
                            sorted(names),
                        ))

            bdist_table = collect_bdists(lock_data, bdist_specs, wheel_files)
            collect_sdists(project_stamp, lock_data, sdist_specs, sdist_table)

            configuration_names, activated_extras = collect_activated_extras(project.lock, project_id, project_data, lock_data, default_versions, marker_graph, package_versions, native_targets)

            # SCC graph shapes:
            #   scc_graph:        {scc_id -> {member -> markers}}
            #   scc_deps:         {scc_id -> {dep -> markers}}
            #   cfg_package_sccs: {cfg -> {package -> scc_id}}
            scc_graph = {}
            scc_deps = {}
            cfg_package_sccs = {}

            base, groups = group_activations(marker_graph, activated_extras, configuration_names)

            # Only distinct graphs need to intern matching SCCs across configurations.
            scc_id_state = {} if len(groups) > 1 else None
            last_results = {}
            for cfg in configuration_names:
                if cfg in groups:
                    activations, equivalent_cfgs = groups[cfg]
                    edges = activate_extras(base, marker_graph, activations)
                    package_sccs, cfgd_scc_graph, cfgd_scc_deps = collect_sccs(replace_dependencies(edges, replacement_deps), scc_id_state)
                    for equivalent in equivalent_cfgs:
                        cfg_package_sccs[equivalent] = package_sccs
                    if len(equivalent_cfgs) > 1:
                        last_results[equivalent_cfgs[-1]] = (cfgd_scc_graph, cfgd_scc_deps)
                elif cfg in last_results:
                    cfgd_scc_graph, cfgd_scc_deps = last_results.pop(cfg)
                else:
                    continue

                # The first occurrence establishes order and the last supplies
                # the final markers for IDs shared between configurations.
                scc_graph.update(cfgd_scc_graph)
                scc_deps.update(cfgd_scc_deps)

            # A lock may contain dev-only components that no public alias reaches.
            reachable_sccs = {}
            marked_package_cfg_sccs = {}
            for version, configs in activated_extras.items():
                package_cfgs = marked_package_cfg_sccs.setdefault(version[1], {})
                for cfg, extras in configs.items():
                    scc = cfg_package_sccs[cfg][version]
                    reachable_sccs[scc] = True
                    markers = package_cfgs.setdefault(cfg, {}).setdefault(scc, {})
                    for extra_markers in extras.values():
                        markers.update(extra_markers)

            for scc_id in scc_graph.keys():
                if scc_id not in reachable_sccs:
                    scc_graph.pop(scc_id)
                    scc_deps.pop(scc_id)
            for scc_id, deps in scc_deps.items():
                for dep in deps:
                    if type(dep) != "string" and dep[1] not in marked_package_cfg_sccs:
                        fail("SCC {} depends on package {} without a surface alias".format(scc_id, dep[1]))

            if testonly_packages:
                for _ in range(len(scc_graph)):
                    changed = False
                    for scc_id, members in scc_graph.items():
                        member_names = [member[1] for member in members]
                        if not (
                            any([name in testonly_packages for name in member_names]) or
                            any([type(dep) != "string" and dep[1] in testonly_packages for dep in scc_deps.get(scc_id, {})])
                        ):
                            continue
                        for name in member_names:
                            if name not in testonly_packages:
                                testonly_packages[name] = True
                                changed = True
                    if not changed:
                        break

            def build_dep_label(dep):
                name = dep[1]
                label = project_package_label(name) if name in marked_package_cfg_sccs else "//:" + name
                return "@" + project_id + label

            project_has_sbuilds = False
            default_exclusions = merge_exclude_globs(project.default_exclude_glob, (), True)
            editable_project_name = normalize_name(project_name)
            for package in lock_data.get("package", []):
                name = package["name"]
                version = package["version"]
                install_key = package_versions[name][version]
                override_key = (name, version)
                repo_suffix = "{}__{}__{}".format(project_stamp, name, normalize_version(version))
                k = "whl_install__" + repo_suffix
                install_target = "@{}//:install".format(k)
                existing_target = install_table.get(install_key)
                if existing_target != None and existing_target != install_target:
                    # A full override already supplies this package.
                    continue

                source = package["source"]
                if "virtual" in source:
                    if override_key in package_overrides:
                        fail("Virtual package {} in lockfile {} cannot use a modification-only `uv.override_package()` annotation because it is not installed.".format(name, project.lock))
                    continue
                if "editable" in source:
                    if name != editable_project_name:
                        fail("Editable package {} in lockfile {} doesn't have a mandatory `uv.override_package(target = ...)` annotation!".format(name, project.lock))
                    if override_key in package_overrides:
                        fail("Editable project package {} in lockfile {} cannot use a modification-only `uv.override_package()` annotation because the workspace supplies it.".format(name, project.lock))
                    continue

                install_table[install_key] = install_target
                sbuild_id = "sdist_build__" + repo_suffix
                sdist = sdist_table.get(sbuild_id)
                pkg_override = package_overrides.get(override_key)
                sbuild_console_scripts = package_console_scripts.get(override_key)
                is_no_binary = name in no_binary_packages or bool(pkg_override and pkg_override.pre_build_patches)

                if is_no_binary and not sdist:
                    fail("Package {} requires a source build but has no sdist in the lockfile".format(name))
                if pkg_override and not sdist:
                    validate_build_attrs(
                        console_scripts = sbuild_console_scripts,
                        resource_set = pkg_override.resource_set,
                        env = pkg_override.env,
                        config_settings = pkg_override.config_settings,
                        error = "uv.override_package() for '{}=={}' in lock '{}': build-only attributes require a source distribution, but the lock record has only wheels: {{}}".format(
                            name,
                            version,
                            project.lock,
                        ),
                        monitor_memory = pkg_override.monitor_memory,
                        pre_build_patches = pkg_override.pre_build_patches,
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip,
                        supported = [],
                        toolchains = pkg_override.toolchains,
                    )
                if sdist:
                    project_has_sbuilds = True
                    build_tool = pkg_override.build_tool if pkg_override else None
                    is_native = "auto"
                    if install_key in lock_native_anns:
                        is_native = "true" if lock_native_anns[install_key] else "false"
                    build_dep_labels = []
                    if not build_tool:
                        if lock_build_deps == None:
                            # Require build tools only for known mandatory source builds.
                            # A target platform without a matching wheel can still need a fallback.
                            sbuild_required = is_no_binary or not package.get("wheels", [])
                            lock_build_deps = {
                                dep: build_dep_label(dep)
                                for req in project.default_build_dependencies
                                for dep, _ in extract_requirement_marker_pairs(project.lock, req, default_versions, package_versions, fail_if_missing = sbuild_required)
                            }
                            lock_build_dep_labels = lock_build_deps.values()
                        build_dep_labels = lock_build_dep_labels
                        annotated_deps = lock_build_dep_anns.get(install_key)
                        if annotated_deps:
                            build_deps = {dep: build_dep_label(dep) for dep in annotated_deps}
                            build_deps.update(lock_build_deps)
                            build_dep_labels = build_deps.values()

                    pre_build_patches = []
                    pre_build_patch_strip = 1
                    if pkg_override and pkg_override.pre_build_patches:
                        pre_build_patches = [str(p) for p in pkg_override.pre_build_patches]
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip

                    # `toolchains` / `env` on `uv.override_package` augment
                    # the defaults baked into sdist_build's BUILD template —
                    # they don't replace them. Empty == no augmentation.
                    extra_toolchains = []
                    extra_env = {}
                    config_settings = {}
                    monitor_memory = False
                    resource_set = "default"
                    if pkg_override:
                        extra_toolchains = [str(t) for t in pkg_override.toolchains]
                        extra_env = pkg_override.env
                        config_settings = pkg_override.config_settings
                        monitor_memory = pkg_override.monitor_memory
                        resource_set = pkg_override.resource_set

                    sbuild_specs[sbuild_id] = struct(
                        src = sdist,
                        deps = build_dep_labels,
                        build_tool = build_tool,
                        is_native = is_native,
                        version = version,
                        pre_build_patches = pre_build_patches,
                        pre_build_patch_strip = pre_build_patch_strip,
                        project_id = project_id,
                        package_install = install_target,
                        extra_toolchains = extra_toolchains,
                        extra_env = extra_env,
                        config_settings = config_settings,
                        monitor_memory = monitor_memory,
                        resource_set = resource_set,
                    )

                post_install_patches = []
                post_install_patch_strip = 1
                default_applies = not default_exclude_packages or name in default_exclude_packages
                exclude_glob = default_exclusions if default_applies else []
                if pkg_override:
                    exclude_glob = merge_exclude_globs(
                        exclude_glob,
                        pkg_override.exclude_glob,
                        pkg_override.inherit_default_exclude_glob,
                    )
                extra_deps = []
                extra_data = []
                if pkg_override and not pkg_override.target:
                    post_install_patches = [str(p) for p in pkg_override.post_install_patches]
                    post_install_patch_strip = pkg_override.post_install_patch_strip
                    extra_deps = [str(d) for d in pkg_override.extra_deps]
                    extra_data = [str(d) for d in pkg_override.extra_data]

                # uv can emit multiple lock records for the same package/version
                # (e.g. resolution-marker forks), each carrying a different
                # subset of wheels. Merge with any previously translated record
                # for the same install instead of overwriting (and thus
                # dropping) it.
                whls = {}
                if not is_no_binary:
                    prev_cfg = install_cfgs.get(k)
                    if prev_cfg:
                        whls.update(prev_cfg.whls)
                    for whl in package.get("wheels", []):
                        basename, target = bdist_table[whl["url"]]
                        whls[basename] = target

                install_cfgs[k] = struct(
                    whls = whls,
                    sbuild = "@{}//:whl".format(sbuild_id) if sdist else None,
                    sbuild_console_scripts = sbuild_console_scripts,
                    post_install_patches = post_install_patches,
                    post_install_patch_strip = post_install_patch_strip,
                    exclude_glob = exclude_glob,
                    extra_deps = extra_deps,
                    extra_data = extra_data,
                    testonly = pkg_override.testonly if pkg_override else False,
                )

            # Build requirements need their runtime dependencies even when
            # neither is activated by the consuming project's dependency group.
            # Keep this graph separate from the runtime aliases and Gazelle index.
            project_build_deps = None
            build_component_owners = {}
            if project_has_sbuilds:
                build_package_keys = {}
                for package in lock_data.get("package", []):
                    if "editable" in package.get("source", {}) or "virtual" in package.get("source", {}):
                        continue
                    pkg_name = package["name"]
                    package_key = package_versions[pkg_name][package["version"]]
                    markers = build_package_keys.setdefault(pkg_name, {}).setdefault(package_key, {})
                    for marker in package.get("resolution-markers") or ("",):
                        markers[marker] = 1
                build_dep_to_scc, build_scc_graph, build_scc_deps = collect_build_deps(replace_dependencies(marker_graph, replacement_deps))
                build_packages = {
                    pkg_name: [
                        {
                            "deps": [
                                install_table[package_key],
                                "//private/build_deps/sccs:" + build_dep_to_scc[package_key],
                            ],
                            "markers": versions[package_key],
                        }
                        for package_key in sorted(versions)
                    ]
                    for pkg_name, versions in build_package_keys.items()
                }

                # Activation-only and conditional entry components do not all
                # have a base requirement. Keep their original logical owner.
                build_component_owners = {
                    component: min([key[1] for key in members])
                    for component, members in build_scc_graph.items()
                }
                marked_build_scc_graph = map_scc_installs(build_scc_graph, install_table)
                for scc_id, deps in build_scc_deps.items():
                    for dep, markers in deps.items():
                        target = dep if type(dep) == "string" else "//private/build_deps/sccs:" + build_dep_to_scc[dep]
                        marked_build_scc_graph[scc_id].setdefault(target, {}).update(markers)

                project_build_deps = {
                    "packages": build_packages,
                    "scc_graph": marked_build_scc_graph,
                }

            def wheel_package(member):
                # A full replacement supplies a library, not a generated wheel target.
                package = member[1]
                override = package_overrides.get((package, member[2]))
                return None if override and override.target != None else package

            project_cfgs[project_id] = dict(
                build_deps = project_build_deps,
                build_component_owners = build_component_owners,
                dep_to_scc = marked_package_cfg_sccs,
                testonly_packages = testonly_packages,
                scc_deps = {
                    k: _merge_scc_dep_markers(deps)
                    for k, deps in scc_deps.items()
                },
                scc_graph = {
                    scc_id: [
                        (install_table[member], wheel_package(member), markers)
                        for member, markers in members.items()
                        if member in install_table
                    ]
                    for scc_id, members in scc_graph.items()
                },
            )

            hub_cfg = hub_cfgs.setdefault(project.hub_name, struct(
                configurations = {},
                packages = {},
                testonly_packages = {},
            ))
            hub_cfg.testonly_packages.update(testonly_packages)

            project_index = "@" + project_id + "//:gazelle_index_whls"
            for cfg in configuration_names:
                if cfg in hub_cfg.configurations:
                    fail("Conflict on configuration name {} in hub {}".format(cfg, project.hub_name))
                hub_cfg.configurations[cfg] = project_index

            for package, groups in marked_package_cfg_sccs.items():
                hub_cfg.packages.setdefault(package, []).extend(groups.keys())

        for i, override in enumerate(mod.tags.override_package):
            if override.lock == None and i not in unscoped_matches:
                if override.version:
                    fail("uv.override_package() for '{}=={}' matches no uv.project() locks in module '{}'.".format(override.name, override.version, mod.name))
                fail("uv.override_package() for '{}' matches no uv.project() locks in module '{}'.".format(override.name, mod.name))

    # Collapse installs that resolve identically across lock universes into one
    # repo, then rewrite install labels in the runtime and build-dependency
    # graphs so dropped ids leave no dangling references.
    id_remap = dedupe_shared_installs(install_cfgs)
    if id_remap:
        target_remap = {
            "@{}//:install".format(dropped): "@{}//:install".format(canonical)
            for dropped, canonical in id_remap.items()
        }
        for project_cfg in project_cfgs.values():
            for members in project_cfg["scc_graph"].values():
                for i, (install, package, markers) in enumerate(members):
                    if install in target_remap:
                        members[i] = (target_remap[install], package, markers)
            build = project_cfg["build_deps"]
            if build != None:
                for candidates in build["packages"].values():
                    for candidate in candidates:
                        # The second entry is a local build component, not an install.
                        deps = candidate["deps"]
                        deps[0] = target_remap.get(deps[0], deps[0])
                for component, members in build["scc_graph"].items():
                    for label in members:
                        if label in target_remap:
                            build["scc_graph"][component] = {
                                target_remap.get(target, target): markers
                                for target, markers in members.items()
                            }
                            break

    return struct(
        project_cfgs = project_cfgs,
        hub_cfgs = hub_cfgs,
        install_cfgs = install_cfgs,
        sbuild_cfgs = sbuild_specs,
        whl_cfgs = collect_configurations(wheel_files),
        sdist_cfgs = sdist_specs,
        bdist_cfgs = bdist_specs,
    )

def _uv_impl(module_ctx):
    """Register the wheel, source-build, project, and hub repositories."""
    # Modules can share a hub name. Projects use their venv to disambiguate.
    declared_hubs = {hub.hub_name: True for mod in module_ctx.modules for hub in mod.tags.declare_hub}
    cfg = _parse_projects(module_ctx, declared_hubs)

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = cfg.whl_cfgs,
    )

    for sdist_name, sdist_cfg in cfg.sdist_cfgs.items():
        if "file" in sdist_cfg:
            sdist_cfg = sdist_cfg["file"]
            http_file(
                name = sdist_name,
                url = sdist_cfg["url"],
                sha256 = _dist_sha256(sdist_cfg),
                downloaded_file_path = url_basename(sdist_cfg["url"]),
            )

        elif "git" in sdist_cfg:
            git_cfg = sdist_cfg["git"]
            git_archive(
                name = sdist_name,
                remote = git_cfg["remote"],
                commit = git_cfg.get("commit"),
                ref = git_cfg.get("ref"),
            )

        else:
            fail("Unsupported archive! {}".format(repr(sdist_cfg)))

    # Derive filtered layouts once when every consumer agrees on its exclusions.
    # Shared wheels with conflicting exclusions retain their RECORD paths so
    # each install can derive its own layout.
    bdist_exclusions = {}
    for install_cfg in cfg.install_cfgs.values():
        exclusions = install_cfg.exclude_glob
        for label in install_cfg.whls.values():
            if bdist_exclusions.setdefault(label, exclusions) != exclusions:
                bdist_exclusions[label] = None

    for label, (name, filename, dist) in cfg.bdist_cfgs.items():
        # A per-wheel repo that downloads the wheel AND peeks its RECORD for the
        # install layout, so only the wheel a config selects is ever fetched.
        exclusions = bdist_exclusions.get(label, [])
        whl_dist(
            name = name,
            url = dist["url"],
            sha256 = _dist_sha256(dist) or "",
            downloaded_file_path = filename,
            exclude_glob = exclusions or [],
            carry_record_paths = exclusions == None,
        )

    # Resolve the sdist configure tool. The default is our bundled
    # detect_native.py, run with a PBS interpreter for the host platform.
    default_configure_interpreter = resolve_host_interpreter_label(module_ctx) if cfg.sbuild_cfgs else None

    for sbuild_id, sbuild_cfg in cfg.sbuild_cfgs.items():
        build_graph = "@{}__build_graph//:".format(sbuild_cfg.project_id)
        sbuild_kwargs = {}
        if default_configure_interpreter:
            sbuild_kwargs["configure_interpreter"] = default_configure_interpreter
            if not sbuild_cfg.build_tool:
                sbuild_kwargs["dependency_records"] = build_graph + "BUILD.bazel"

        if sbuild_cfg.pre_build_patches:
            sbuild_kwargs["pre_build_patches"] = sbuild_cfg.pre_build_patches
            sbuild_kwargs["pre_build_patch_strip"] = sbuild_cfg.pre_build_patch_strip
        if sbuild_cfg.extra_toolchains:
            sbuild_kwargs["extra_toolchains"] = sbuild_cfg.extra_toolchains
        if sbuild_cfg.extra_env:
            sbuild_kwargs["extra_env"] = sbuild_cfg.extra_env
        if sbuild_cfg.config_settings:
            sbuild_kwargs["config_settings"] = sbuild_cfg.config_settings
        if sbuild_cfg.monitor_memory:
            sbuild_kwargs["monitor_memory"] = True
        if sbuild_cfg.resource_set != "default":
            sbuild_kwargs["resource_set"] = sbuild_cfg.resource_set
        sdist_build(
            name = sbuild_id,
            available_deps_file = build_graph + "available_deps.json",
            build_deps_file = build_graph + "build_deps.json",
            package_install = sbuild_cfg.package_install,
            src = sbuild_cfg.src,
            deps = sbuild_cfg.deps,
            build_tool = sbuild_cfg.build_tool,
            is_native = sbuild_cfg.is_native,
            version = sbuild_cfg.version,
            **sbuild_kwargs
        )

    for install_id, install_cfg in cfg.install_cfgs.items():
        install_kwargs = {}
        if install_cfg.sbuild_console_scripts != None:
            install_kwargs["sbuild_console_scripts_override"] = True
        if install_cfg.post_install_patches:
            install_kwargs["post_install_patches"] = json.encode(install_cfg.post_install_patches)
            install_kwargs["post_install_patch_strip"] = install_cfg.post_install_patch_strip
        if install_cfg.exclude_glob:
            install_kwargs["exclude_glob"] = install_cfg.exclude_glob
        if install_cfg.extra_deps:
            install_kwargs["extra_deps"] = json.encode(install_cfg.extra_deps)
        if install_cfg.extra_data:
            install_kwargs["extra_data"] = json.encode(install_cfg.extra_data)
        if install_cfg.testonly:
            install_kwargs["package_testonly"] = True
        whl_install(
            name = install_id,
            sbuild = install_cfg.sbuild,
            sbuild_console_scripts = install_cfg.sbuild_console_scripts or [],
            whls = install_cfg.whls,
            wheel_configurations = "@aspect_rules_py_pip_configurations//:BUILD.bazel",
            **install_kwargs
        )

    for project_id, project_cfg in cfg.project_cfgs.items():
        declare_project(name = project_id, **project_cfg)

    for hub_id, hub_cfg in cfg.hub_cfgs.items():
        uv_hub(
            name = hub_id,
            configurations = hub_cfg.configurations,
            packages = {name: sorted(groups) for name, groups in hub_cfg.packages.items()},
            testonly_packages = sorted(hub_cfg.testonly_packages),
        )

    return module_ctx.extension_metadata(reproducible = True)

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
    },
    doc = """Declare a named hub: a shared dependency namespace that `uv.project()` registrations bind to.""",
)

_project_tag = tag_class(
    attrs = {
        "default_exclude_glob": attr.string_list(
            default = [],
            doc = "Site-packages-relative exclusions applied after wheel installation.",
        ),
        "default_exclude_packages": attr.string_list(
            default = [],
            doc = "Normalized package names inheriting project exclusions; empty matches all.",
        ),
        "hub_name": attr.string(
            mandatory = True,
            doc = "Name of a hub previously declared with `uv.declare_hub`.",
        ),
        "name": attr.string(
            mandatory = False,
            doc = "Override the project name; defaults to `[project].name` in `pyproject.toml`.",
        ),
        "version": attr.string(
            mandatory = False,
            doc = "Override the project version; defaults to `[project].version` in `pyproject.toml`.",
        ),
        "pyproject": attr.label(
            mandatory = True,
            doc = "The `pyproject.toml` describing this project.",
        ),
        "lock": attr.label(
            mandatory = True,
            doc = "The `uv.lock` pinning this project's dependency graph.",
        ),
        "default_build_dependencies": attr.string_list(
            mandatory = False,
            default = [
                "build",
            ],
            doc = "Requirement names resolved from the lock and injected as build tools " +
                  "for sdists that build a wheel. Only demanded when an sbuild is " +
                  "guaranteed to be selected (forced builds or sdist-only packages).",
        ),
    },
    doc = """Register a `pyproject.toml` + `uv.lock` pair into a hub, resolving the project's locked dependency graph.""",
)

_annotations_tag = tag_class(
    attrs = {
        "lock": attr.label(
            mandatory = False,
            doc = "The `uv.lock` these annotations apply to. Omit it to apply across every `uv.project()` in the same module.",
        ),
        "src": attr.label(
            mandatory = True,
            doc = "TOML file of per-package annotations (`[package]` tables carrying `native` and/or `build-dependencies`).",
        ),
    },
    doc = """Attach per-package build annotations (native flag, extra build-dependencies) from a TOML file to one lock or all project locks in the same module.""",
)

_override_package_tag = tag_class(
    attrs = {
        "exclude_locks": attr.label_list(
            doc = "Registered locks omitted from a module-wide override.",
        ),
        "lock": attr.label(
            mandatory = False,
            doc = "The `uv.lock` this override applies to. Omit it to apply the override across every `uv.project()` declared by the same module.",
        ),
        "name": attr.string(mandatory = True),
        "testonly": attr.bool(
            default = False,
            doc = "Restrict this package and its generated Bazel targets to test-only consumers.",
        ),
        "version": attr.string(mandatory = False),
        "target": attr.label(
            mandatory = False,
            doc = "A target that replaces the installed package while retaining locked dependency edges. " +
                  "Mutually exclusive with all modification attributes.",
        ),
        "build_tool": attr.label(
            doc = "Executable implementing the build_helper.py CLI, including --check-build-dependencies. " +
                  "Replaces the generated frontend and its entire dependency environment; the tool owns " +
                  "all build requirements and must inherit the selected Python version and ABI. " +
                  "Declared requirements are validated before building. Applies only to source builds.",
        ),
        "console_scripts": attr.string_dict(
            default = _CONSOLE_SCRIPTS_UNSET,
            doc = "Complete console scripts for a source-built wheel, mapping script names to module:object entry points. An explicit empty map suppresses all detected scripts.",
        ),
        "monitor_memory": attr.bool(
            default = False,
            doc = "Report approximate Linux process-tree RSS while building this package's wheel.",
        ),
        "resource_set": attr.string(
            default = "default",
            values = resource_set_values,
            doc = "Local execution resources to reserve for this package's wheel build action. " +
                  "One of bazel-lib's predefined resource sets ('mem_512m', 'mem_1g', … 'mem_32g', " +
                  "'cpu_2', 'cpu_4', 'default'). Bazel rounds a memory request up to the named " +
                  "bucket.",
        ),
        "toolchains": attr.label_list(
            default = [],
            doc = "Extra toolchain targets forwarded to the generated pep517_native_whl(...) call's `toolchains` list. Each target's TemplateVariableInfo make-variables become available for $(VAR) expansion in `env`; the well-known ones (CARGO, RUSTC, RUST_HOST_SYSROOT, JAVA, JAVABASE, ANT_HOME, ANT_BIN_DIR) reach the build environment automatically.",
        ),
        "env": attr.string_dict(
            default = {},
            doc = "Extra environment variables merged into the build action's `env` dict. Values may reference $(VAR) make-variables sourced from extra `toolchains` listed above. Prefix an execroot-relative path with `$(EXECROOT)/` so it remains valid after the backend changes into the unpacked source tree. Omit CC/CXX/AR/LD/STRIP to use the configured C++ action tools.",
        ),
        "config_settings": attr.string_list_dict(
            default = {},
            doc = "PEP 517 `config_settings` for this package's build backend. Each key maps to a list of values: a single value reaches the backend as a string, several as a list. Keys and their meaning are defined by the backend, e.g. `{\"setup-args\": [\"-Dblas=none\"]}` for meson-python or `{\"cmake.define.FOO\": [\"1\"]}` for scikit-build-core. Applies to pure and native source builds.",
        ),
        "pre_build_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the sdist source tree before building a wheel.",
        ),
        "pre_build_patch_strip": attr.int(
            default = 1,
            doc = "Strip count for pre-build patches (-p flag to the patch tool).",
        ),
        "post_install_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the installed package after wheel unpacking. Paths are site-packages-relative.",
        ),
        "post_install_patch_strip": attr.int(
            default = 1,
            doc = "Strip count for post-install patches (-p flag to the patch tool).",
        ),
        "exclude_glob": attr.string_list(
            default = [],
            doc = "Site-packages-relative glob patterns to remove after wheel installation (e.g. 'numpy/**/tests/**').",
        ),
        "inherit_default_exclude_glob": attr.bool(
            default = True,
            doc = "Apply project defaults before package-specific wheel exclusions.",
        ),
        "replacement_deps": attr.string_keyed_label_dict(
            default = {},
            doc = "Map direct locked dependency names to Bazel labels in emitted runtime and build dependency graphs. Names are normalized and must occur in the original base or extra edges. Replaced edges retain their markers and extra activation; other locked edges, package activation, wheel metadata, and the package's own build requirements are unchanged. Direct wheel-install targets bypass dependency graphs. Bazel analysis checks cycles involving replacement labels.",
        ),
        "extra_deps": attr.label_list(
            default = [],
            doc = "Additional deps to add to the package's py_library target.",
        ),
        "extra_data": attr.label_list(
            default = [],
            doc = "Additional data files to add to the package's py_library target.",
        ),
    },
    doc = """Override or modify a Python package resolved from a lockfile.

Use `target` to replace the installed package, or use modification attributes
to change its installation or named dependency edges. Locked dependencies are
otherwise inherited. Omitting `lock` applies the override across all project
locks declared by the same module. `target` is mutually exclusive with
modifications.""",
)

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
    },
)
