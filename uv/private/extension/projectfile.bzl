"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version", "version_satisfies")
load(":dep_groups.bzl", "resolve_dependency_group_specs")
load(":marker_simplify.bzl", "add_minimal_clause", "clause_marker")

def extract_requirement_marker_pairs(projectfile, req_string, version_map, package_versions = {}, fail_if_missing = True, release_markers = {}):
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
        release_markers: Marker domains of platform- or interpreter-specific releases.
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

    specifier = remainder.strip()
    versions = package_versions.get(pkg_name, {})
    if len(versions) > 1 and all([(pkg_name, version) in release_markers for version in versions]):
        # uv locked a release for each environment. A broad requirement
        # activates all matching releases inside their respective forks.
        releases = [
            release
            for version, release in versions.items()
            if not specifier or version_satisfies(version, specifier)
        ]
    else:
        release = version_map.get(pkg_name)
        if versions and (release == None or (specifier and not version_satisfies(release[2], specifier))):
            release = find_matching_version(specifier or ">=0", versions) or release
        releases = [release] if release != None else []
    if not releases and fail_if_missing:
        fail("Unable to resolve requirement {} in {}".format(repr(req_string), projectfile))
    return [
        ((lock_id, name, version, extra), marker)
        for lock_id, name, version, _ in releases
        for extra in extras
    ]

def _release_markers(lock_data):
    markers = {}
    for package in lock_data.get("package", []):
        key = (normalize_name(package["name"]), package.get("version"))
        for marker in package.get("resolution-markers") or ("",):
            markers.setdefault(key, {})[marker] = 1
    forks = {}
    for key, alternatives in markers.items():
        if "" in alternatives:
            continue
        if len(alternatives) == 1:
            forks[key] = alternatives.keys()[0]
        else:
            forks[key] = " or ".join(["({})".format(marker) for marker in sorted(alternatives)])
    return forks

def _with_marker(clause, marker):
    if not marker or marker in clause:
        return clause
    return tuple(sorted(clause + (marker,))) if clause else (marker,)

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
    forks = _release_markers(lock_data)
    activated_extras = {}

    for group_name in dep_groups:
        group_clauses = {}
        for spec in resolve_dependency_group_specs(dep_groups, group_name):
            pairs = extract_requirement_marker_pairs(
                projectfile,
                spec,
                default_versions,
                package_versions,
                release_markers = forks,
            )
            for dep, marker in pairs:
                clause = _with_marker((marker,) if marker else (), forks.get((dep[1], dep[2])))
                add_minimal_clause(group_clauses.setdefault(dep, {}), clause)

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

                # The graph edge already identifies the exact version uv chose.
                # Its marker is relative to the requester, so also restrict it
                # to the selected version's own resolution fork.
                for target_dep, edge_markers in graph.get(parent_dep, {}).items():
                    target_clauses = group_clauses.setdefault(target_dep, {})
                    if () in target_clauses:
                        continue
                    scoped = _with_marker(parent_clause, forks.get((target_dep[1], target_dep[2])))
                    for edge_marker in edge_markers:
                        clause = _with_marker(scoped, edge_marker)
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
