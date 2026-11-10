"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version", "version_satisfies")
load(":dep_groups.bzl", "resolve_dependency_group_specs")
load(":marker_simplify.bzl", "add_minimal_clause", "clause_marker")

def extract_requirement_marker_pairs(projectfile, req_string, version_map, package_versions = {}, preferred_versions = {}, fail_if_missing = True):
    """Parses a requirement string into a list of dependency-marker pairs.

    This function parses a PEP 508 requirement string (e.g.,
    "requests[security]>=2.0; python_version < '3.8'") and converts it into a
    list of pairs, where each pair contains a `Dependency` tuple and a `Marker`
    string.

    Args:
        req_string: The requirement string to parse.
        version_map: A dictionary mapping package names to their default version
            dependency tuples.
        package_versions: The version-to-dependency indexes returned by normalize_lock.
        fail_if_missing: If True (the default), fail when the requirement's
            package can't be located in the lockfile. If False, return an empty
            list — useful for advisory requirements like the project-level
            `default_build_dependencies`, which may legitimately be absent
            from lockfiles that ship no sdists needing the build tooling.

    Returns:
        A list of tuples, where each tuple is `(Dependency, Marker)`.
    """

    req_part, _, marker = req_string.partition(";")
    req_part = req_part.strip()
    marker = marker.strip()
    if not req_part:
        return []

    name_end_idx = 0
    for char in req_part.elems():
        if char in "[=><!~ ":
            break
        name_end_idx += 1

    pkg_name = normalize_name(req_part[:name_end_idx])

    extras = ["__base__"]

    remainder = req_part[name_end_idx:]

    if remainder.startswith("["):
        close_idx = remainder.find("]")
        if close_idx != -1:
            content = remainder[1:close_idx]
            parts = content.split(",")
            for project_data in parts:
                clean_p = project_data.strip()
                if clean_p:
                    extras.append(clean_p)
            remainder = remainder[close_idx + 1:]

    # A group preference or default version is used only when it satisfies
    # the specifier; disjoint-marker requirements on one package need distinct
    # lockfile versions. Otherwise match against all lockfile versions, then
    # fall back to the unchecked preference.
    specifier = remainder.strip()
    known = [preferred_versions.get(pkg_name), version_map.get(pkg_name)]
    v = None
    for candidate in known:
        if candidate != None and (not specifier or version_satisfies(candidate[2], specifier)):
            v = candidate
            break
    if v == None:
        candidates = package_versions.get(pkg_name)
        if candidates:
            v = find_matching_version(specifier or ">=0", candidates)
    if v == None:
        v = known[0] or known[1]
    if v == None:
        if not fail_if_missing:
            return []
        fail("Unable to resolve a default version for requirement {} in {}".format(repr(req_string), projectfile))

    lock_id, pkg_name, version, _ = v
    return [((lock_id, pkg_name, version, extra), marker) for extra in extras]

def _extract_lockfile_group_versions(lock_id, lock_data):
    """Extracts resolved package versions per dependency group from the lockfile.

    uv.lock encodes the exact package versions selected for each dependency group
    in the root package's `dev-dependencies` section. This function builds a map
    that can be used as `preferred_versions` when resolving requirement strings.

    Args:
        lock_id: The lockfile identifier used in dependency tuples.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary mapping normalized group names to dictionaries of
        {package_name: (lock_id, package_name, version, "__base__")}.
    """
    result = {}
    for pkg in lock_data.get("package", []):
        if "virtual" not in pkg.get("source", {}):
            continue
        for raw_group_name, deps in pkg.get("dev-dependencies", {}).items():
            group_name = normalize_name(raw_group_name)
            for dep in deps:
                if "version" in dep:
                    pkg_name = normalize_name(dep["name"])
                    result.setdefault(group_name, {})[pkg_name] = (lock_id, pkg_name, dep["version"], "__base__")
    return result

def collect_activated_extras(projectfile, lock_id, project_data, lock_data, default_versions, graph, package_versions = {}, native_targets = {}):
    """Collects the set of transitively activated extras for each configuration.

    This function determines the full set of extras that are activated for each
    dependency group defined in the `pyproject.toml`. It performs a transitive
    traversal of the dependency graph to find all extras that are pulled in by
    the initial set of requirements.

    Args:
        project_data: The parsed content of the `pyproject.toml` file.
        default_versions: A dictionary mapping package names to their default
            version dependency tuples.
        graph: The dependency graph, as returned by `normalize_lock`.

    Returns:
        A tuple containing:
        - A dictionary of configuration names.
        - A dictionary mapping each dependency to a dictionary of configurations
          that activate it, which in turn maps to a dictionary of the extra
          dependencies and their markers. The structure is:
          `{dep: {cfg: {extra_dep: {marker: 1}}}}`.
    """

    # Use the lock manifest or the project itself when no groups are declared.
    runtime_group = project_data["project"]["name"]
    dep_groups = project_data.get("dependency-groups", {
        runtime_group: lock_data.get("manifest", {}).get("members", [runtime_group]),
    })
    project_root = default_versions.get(normalize_name(runtime_group))
    lockfile_group_versions = _extract_lockfile_group_versions(lock_id, lock_data)
    activated_extras = {}

    for group_name in dep_groups:
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)

        group_preferences = dict(lockfile_group_versions.get(group_name, {}))

        # Record the sole resolved version for each direct package. None means
        # its requirements resolved to multiple versions, so keep no preference.
        direct_versions = {}
        for spec in resolved_specs:
            pairs = extract_requirement_marker_pairs(projectfile, spec, default_versions, package_versions, group_preferences)
            if pairs:
                base, _ = pairs[0]
                if direct_versions.setdefault(base[1], base) != base:
                    direct_versions[base[1]] = None

        for package, version in direct_versions.items():
            if version == None:
                group_preferences.pop(package, None)
            else:
                group_preferences[package] = version

        # For each dependency, keep only the minimal marker conjunctions under
        # which it is reachable.
        group_clauses = {}
        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, spec, default_versions, package_versions, group_preferences):
                add_minimal_clause(group_clauses.setdefault(dep, {}), (marker,) if marker else ())

        # Native replacements do not need a matching wheel. Keep the locked
        # dependency edges and expose only packages declared by a runtime root.
        if group_name == runtime_group and () in group_clauses.get(project_root, {}):
            root_deps = graph.get(project_root, {})
            for dep in native_targets:
                if dep in root_deps:
                    group_clauses[dep] = {(): 1}

        worklist = [
            (dep, clause)
            for dep, clauses in group_clauses.items()
            for clause in clauses
        ]

        # Every minimal clause has a simple-path witness, so one round per
        # node plus one to drain reaches the fixed point.
        for _ in range(len(graph) + 1):
            if not worklist:
                break

            next_worklist = []
            for parent_dep, parent_clause in worklist:
                if parent_clause not in group_clauses[parent_dep]:
                    continue

                for next_dep, edge_markers in graph.get(parent_dep, {}).items():
                    pref = group_preferences.get(next_dep[1])
                    target_dep = next_dep
                    if pref and pref[2] != next_dep[2]:
                        target_dep = (next_dep[0], next_dep[1], pref[2], next_dep[3])

                    target_clauses = group_clauses.get(target_dep)
                    if target_clauses == None:
                        target_clauses = {}
                        group_clauses[target_dep] = target_clauses
                    if () in target_clauses:
                        continue

                    for edge_marker in edge_markers:
                        clause = parent_clause
                        if edge_marker and edge_marker not in parent_clause:
                            clause = tuple(sorted(parent_clause + (edge_marker,))) if parent_clause else (edge_marker,)
                        if add_minimal_clause(target_clauses, clause):
                            next_worklist.append((target_dep, clause))

            worklist = next_worklist

        if worklist:
            fail("Marker propagation did not converge for dependency group {} in {}".format(repr(group_name), projectfile))

        for dep, clauses in group_clauses.items():
            base = dep if dep[3] == "__base__" else (dep[0], dep[1], dep[2], "__base__")
            activated_extras.setdefault(base, {}).setdefault(group_name, {})[dep] = {
                clause_marker(clause): 1
                for clause in clauses
            }

    return {group: 1 for group in dep_groups}, activated_extras
