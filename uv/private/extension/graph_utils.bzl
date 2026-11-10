load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private/graph:sccs.bzl", "sccs")
load(":marker_simplify.bzl", "add_minimal_clause", "clause_marker")

def _derive_scc_id(scc_members, stems):
    """Derive a deterministic, readable SCC id from the SCC's members.

    A lone base package (the overwhelmingly common case) gets
    `<name>__<version>`; a genuine cycle is named by its member packages.
    `stems` disambiguates repeat stems with a `__v<n>` suffix.
    """
    if len(scc_members) == 1 and scc_members[0][3] == "__base__":
        member = scc_members[0]
        stem = "{}__{}".format(member[1], normalize_version(member[2]))
    else:
        names = sorted([m[1] for m in scc_members])
        if len(names) > 4:
            names = names[:4] + ["and_{}_more".format(len(scc_members) - 4)]
        stem = "cycle__" + "__".join(names)
    n = stems.get(stem, 0)
    stems[stem] = n + 1
    return stem if n == 0 else "{}__v{}".format(stem, n)

def collect_sccs(marker_graph, id_state = None):
    """Computes Strongly Connected Components (SCCs) for a dependency marker_graph.

    This function takes a dependency marker_graph and identifies all the SCCs, which
    are groups of packages that have cyclic dependencies on each other.

    Args:
        marker_graph: The dependency graph, as returned by `normalize_lock`.
        {pkg: {dep: {marker: 1}}}. Dependencies may be lock tuples or absolute
        Bazel-label strings; labels remain external to the SCC topology.
        id_state: dict carrying SCC id intern state. Pass the same dict for
        every configuration of one project: identical SCC content reuses one
        id (the caller aggregates by id), while an SCC with the same members
        but different external deps/markers gets a distinct id.

    Returns:
        A tuple containing:
        - A dictionary mapping each dependency to the ID of the SCC that
          contains it.
        - A dictionary representing the marker_graph of SCCs, where the keys are SCC IDs
          and the values are dictionaries of member dependencies and their
          markers.
        - A dictionary mapping each SCC ID to its direct, non-member
          dependencies.
    """

    graph = {}
    for member, deps in marker_graph.items():
        neighbors = [dep for dep in deps if type(dep) != "string"]
        graph[member] = neighbors
        for dep in neighbors:
            graph.setdefault(dep, ())

    dep_to_scc = {}
    scc_graph = {}
    scc_deps = {}
    interned_ids = id_state.setdefault("ids", {}) if id_state != None else None
    stems = id_state.setdefault("stems", {}) if id_state != None else {}
    for members in sccs(graph):
        internal = {member: {} for member in members}
        external = {}
        for member in members:
            for dep, markers in marker_graph.get(member, {}).items():
                if dep in internal:
                    internal[dep].update(markers)
                elif dep in external:
                    external[dep].update(markers)
                else:
                    external[dep] = dict(markers)

        if interned_ids == None:
            component = _derive_scc_id(members, stems)
        else:
            # Label strings and four-field lock tuples may coexist in one SCC.
            # Give each edge a tuple key so sorting uses a single type.
            edges = tuple(sorted([
                ((dep,) if type(dep) == "string" else dep, tuple(markers.items()))
                for dep, markers in external.items()
            ]))
            content = (tuple(members), edges)
            component = interned_ids.get(content)
            if component == None:
                component = _derive_scc_id(members, stems)
                interned_ids[content] = component

        for member, markers in internal.items():
            dep_to_scc[member] = component
            if not markers:
                markers[""] = 1
        scc_graph[component] = internal
        scc_deps[component] = external

    return dep_to_scc, scc_graph, scc_deps

def collect_build_deps(marker_graph):
    """Collect build dependencies with conditions relative to each cycle entry.

    Args:
        marker_graph: Dependency tuples mapped to dependencies and marker sets.

    Returns:
        A node-to-entry map, entry-to-member markers, and entry-to-external
        dependency markers. Entry targets only depend on other components,
        keeping the generated Bazel graph acyclic.
    """
    dep_to_entry, entry_graph, entry_deps = collect_sccs(marker_graph)
    used_ids = {scc_id: 1 for scc_id in entry_graph}

    def _add_paths(paths, lefts, markers):
        # A path is a conjunction of whole marker expressions. Canonicalize
        # repeated conditions and absorb stronger paths to the same node.
        for left in lefts:
            for marker in markers:
                path = tuple(sorted(left + (marker,))) if marker and marker not in left else left
                add_minimal_clause(paths, path)

    def _markers(paths):
        return {clause_marker(path): 1 for path in paths}

    for scc_id, members in list(entry_graph.items()):
        if all([
            "" in markers
            for member in members
            for dep, markers in marker_graph.get(member, {}).items()
            if dep in members
        ]):
            continue

        entry_graph.pop(scc_id)
        entry_deps.pop(scc_id)
        for i, entry in enumerate(members):
            entry_id = scc_id
            if len(members) > 1:
                stem = "{}__entry_{}".format(scc_id, i)
                for suffix in range(len(used_ids) + 1):
                    entry_id = stem if suffix == 0 else "{}__{}".format(stem, suffix)
                    if entry_id not in used_ids:
                        break
                used_ids[entry_id] = 1
            dep_to_entry[entry] = entry_id
            reachable = {entry: {(): 1}}

            # Every reachable member has a simple path of at most N-1 edges.
            # Use a snapshot each round so cyclic walks cannot extend the bound.
            for _ in range(len(members) - 1):
                next_reachable = {member: dict(paths) for member, paths in reachable.items()}
                for member, paths in reachable.items():
                    for dep, markers in marker_graph.get(member, {}).items():
                        if dep in members:
                            _add_paths(next_reachable.setdefault(dep, {}), paths, markers)
                if next_reachable == reachable:
                    break
                reachable = next_reachable

            deps = {}
            for member, paths in reachable.items():
                for dep, markers in marker_graph.get(member, {}).items():
                    if dep not in members:
                        _add_paths(deps.setdefault(dep, {}), paths, markers)
            entry_graph[entry_id] = {member: _markers(paths) for member, paths in reachable.items()}
            entry_deps[entry_id] = {dep: _markers(paths) for dep, paths in deps.items()}

    return dep_to_entry, entry_graph, entry_deps

def exclude_build_dep(packages, scc_graph, excluded):
    """Remove a consumer's transitive self edge from the build closures that carry it.

    Args:
        packages: Build requirement names mapped to candidates with deps and markers.
        scc_graph: SCC IDs mapped to dependency labels and marker sets.
        excluded: Exact install label of the package being built.

    Returns:
        The package roots reaching the excluded install through their SCC, and
        those SCCs without it. Direct requirements, other installs, and
        dependencies reached through the excluded package are preserved.
    """
    scc_prefix = "//private/build_deps/sccs:"
    parents = {}
    for scc_id, members in scc_graph.items():
        for member in members:
            parents.setdefault(member, []).append(scc_id)

    affected = {}
    frontier = parents.get(excluded, [])
    for _ in range(len(scc_graph)):
        next_frontier = []
        for scc_id in frontier:
            if scc_id not in affected:
                affected[scc_id] = True
                next_frontier.extend(parents.get(scc_prefix + scc_id, []))
        if not next_frontier:
            break
        frontier = next_frontier

    # The source repository redirects the whole package name, so every fork
    # of an affected package comes along.
    affected_packages = {
        name: candidates
        for name, candidates in packages.items()
        if any([
            candidate["deps"][0] != excluded and candidate["deps"][1][len(scc_prefix):] in affected
            for candidate in candidates
        ])
    }
    if not affected_packages:
        return {}, {}

    return affected_packages, {
        scc_id: {
            member: markers
            for member, markers in scc_graph[scc_id].items()
            if member != excluded
        }
        for scc_id in affected
    }

def reachable_build_deps(packages, scc_graph):
    """Select only the SCCs needed by the discovered build requirements.

    Args:
        packages: Selected requirement names mapped to candidates with deps and markers.
        scc_graph: SCC IDs mapped to dependency labels and marker sets.

    Returns:
        The reachable SCCs, including dependencies reached through omitted installs.
    """
    prefix = "//private/build_deps/sccs:"
    frontier = {
        candidate["deps"][1][len(prefix):]: True
        for candidates in packages.values()
        for candidate in candidates
    }
    reachable = {}
    for _ in range(len(scc_graph)):
        next_frontier = {}
        for scc_id in frontier:
            if scc_id in reachable:
                continue
            reachable[scc_id] = scc_graph[scc_id]
            for dep in scc_graph[scc_id]:
                if dep.startswith(prefix):
                    next_frontier[dep[len(prefix):]] = True
        if not next_frontier:
            break
        frontier = next_frontier
    return reachable

def _base_package(package):
    if package[3] == "__base__":
        return package
    return (package[0], package[1], package[2], "__base__")

def replace_dependencies(marker_graph, replacements):
    """Replace named locked edges with absolute labels, retaining their markers.

    replacements maps resolved base-package tuples to normalized dependency names
    and labels. The caller validates names against the original locked graph.
    """
    if not replacements:
        return marker_graph
    result = dict(marker_graph)
    for package, deps in marker_graph.items():
        targets = replacements.get(_base_package(package))
        if not targets:
            continue
        replaced = {}
        for dep, markers in deps.items():
            replaced.setdefault(targets.get(dep[1], dep), {}).update(markers)
        result[package] = replaced
    return result

def _base_edges(edges):
    for dep in edges:
        if dep[3] != "__base__":
            normalized = {}
            for target, markers in edges.items():
                normalized.setdefault(_base_package(target), {}).update(markers)
            return normalized
    return edges

def group_activations(marker_graph, activated_extras, configurations):
    """Normalize base edges and group configurations by their ordered extra activations."""
    base = {}
    activations = {cfg: [] for cfg in configurations}
    for package, edges in marker_graph.items():
        if package[3] != "__base__":
            continue
        base[package] = _base_edges(edges)

        for cfg, extras in activated_extras.get(package, {}).items():
            if cfg not in activations:
                continue
            for extra, markers in extras.items():
                if not marker_graph.get(extra):
                    continue
                if extra == package and len(markers) == 1 and "" in markers:
                    # These unconditional edges are already in base.
                    continue

                # Order matters when several extras contribute markers to the same edge.
                activations[cfg].append((package, extra, tuple(markers)))

    groups = {}
    for cfg, extras in activations.items():
        groups.setdefault(tuple(extras), []).append(cfg)
    return base, {cfgs[0]: (extras, cfgs) for extras, cfgs in groups.items()}

def activate_extras(base, marker_graph, activations):
    """Overlay one group's active extra edges on the shared base graph."""
    if not activations:
        return base
    changed = {}
    for package, extra, markers in activations:
        if package not in changed:
            changed[package] = {dep: dict(conditions) for dep, conditions in base[package].items()}
        deps = changed[package]
        for dep, implied in marker_graph[extra].items():
            conditions = deps.setdefault(_base_package(dep), {})
            for left in markers:
                for right in implied:
                    marker = "({}) and ({})".format(left, right) if left and right else left or right
                    conditions[marker] = 1
    return base | changed
