"""
Machinery specific to interacting with a uv.lock
"""

load("@bazel_lib//lib:strings.bzl", "ord")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/whl_install:repository.bzl", "compatible_python_tags")
load(":git_utils.bzl", "parse_git_url", "try_git_to_http_archive")
load(":marker_simplify.bzl", "simplify_extra_marker")

def fnv1a_64(s):
    """FNV-1a 64-bit hash as a 16-character hex string.

    Used only to generate stable, unique-ish suffixes for repository names
    (e.g. for lockfile distributions that lack a `hash` field). It is not
    a security or integrity mechanism, so a fast non-cryptographic hash is
    sufficient; do not "upgrade" this back to a cryptographic hash.

    Args:
     s: str, the input string (typically a distribution URL).

    Returns:
     the 64-bit hash as a zero-padded 16-character lowercase hex string.
    """
    h = 0xcbf29ce484222325
    for c in s.elems():
        h = ((h ^ ord(c)) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    hex_str = "%x" % h
    return "0" * (16 - len(hex_str)) + hex_str

def url_basename(url):
    """Returns the trailing file name of a distribution URL.

    Lockfile wheel and sdist URLs name the distribution file in the last path
    segment, but registries may append a query string (e.g. signed/expiring
    download links) and/or a fragment (e.g. PEP 503 `#sha256=...` hashes).
    Neither is part of the file name, so both are stripped.

    Args:
        url: str, the URL of a distribution file.

    Returns:
        the file name as a string, e.g. "foo-1.0.0-py3-none-any.whl".
    """
    path = url.partition("?")[0].partition("#")[0]
    basename = path[path.rfind("/") + 1:]
    if not basename:
        fail("Invalid distribution URL (no file name): " + url)
    return basename

def _dist_identifier(dist):
    """Stable short id for a wheel/sdist repo name.

    Lockfile sources without a `hash` field (e.g. find-links registries)
    fall back to hashing the URL, the only field guaranteed present.
    """
    if "hash" in dist:
        return dist["hash"].split(":")[1][:16]
    return fnv1a_64(dist["url"])

def _add_locked_edges(edges, deps, lock_id, default_versions, owner_extra = None):
    for dep in deps:
        raw_name = dep["name"]
        if "version" in dep:
            base = (lock_id, normalize_name(raw_name), dep["version"], "__base__")
        else:
            base = default_versions.get(raw_name) or default_versions[normalize_name(raw_name)]
        marker = dep.get("marker", "")
        if owner_extra != None:
            if marker:
                marker = simplify_extra_marker(marker, owner_extra)
            if marker == None:
                continue

        extras = dep.get("extra", ())
        if "__base__" not in extras:
            edges.setdefault(base, {})[marker] = 1
        for extra in extras:
            target = base if extra == "__base__" else (base[0], base[1], base[2], extra)
            edges.setdefault(target, {})[marker] = 1

def normalize_lock(lock_id, lock_data):
    """Index locked versions and build the graph used to activate dependencies.

    Normalizes package names and fills source archive URLs in the lock records.
    Resolves dependency names and versions as edges are added. The original
    dependency records are left available for consumers of the lock metadata.

    Args:
        lock_id: Project identifier used in dependency tuples.
        lock_data: The parsed content of the uv lockfile.

    Returns:
        The unambiguous default versions, all package versions, and the graph
        from dependency tuples to their ordered edges and markers.
    """
    packages = lock_data.get("package", [])
    package_versions = {}
    for package in packages:
        name = normalize_name(package["name"])
        version = package["version"]
        package["name"] = name
        package_versions.setdefault(name, {})[version] = (lock_id, name, version, "__base__")

        if "sdist" in package and "url" not in package["sdist"]:
            package["sdist"]["url"] = package["source"]["url"]

    default_versions = {
        name: versions.values()[0]
        for name, versions in package_versions.items()
        if len(versions) == 1
    }

    graph = {}
    for package in packages:
        name = package["name"]
        version = package["version"]
        base = package_versions[name][version]
        _add_locked_edges(graph.setdefault(base, {}), package.get("dependencies", ()), lock_id, default_versions)
        for extra, deps in package.get("optional-dependencies", {}).items():
            target = (lock_id, name, version, extra)
            _add_locked_edges(graph.setdefault(target, {}), deps, lock_id, default_versions, owner_extra = extra)

    return default_versions, package_versions, graph

def collect_configurations(wheel_files):
    """Collects the platform configurations needed by the locked wheels.

    This function identifies all the unique combinations of Python implementation,
    platform, and ABI from the wheel filenames in the lockfile.

    Args:
        wheel_files: The ordered set of wheel filenames across all locks.

    Returns:
        A dictionary mapping configuration strings (e.g.,
        "cp39-manylinux_2_17_x86_64-cp39") to a list of `config_setting`
        labels that define the configuration.
    """

    # Configurations depend only on a wheel's trailing tag triple
    # ({python}-{abi}-{platform}.whl); a large lock has thousands of wheel
    # files but only a few dozen distinct triples, so parse and expand one
    # representative wheel per triple.
    tag_triples = {}
    for wheel_name in wheel_files:
        parts = wheel_name.rsplit("-", 3)
        tags = wheel_name[len(parts[0]) + 1:] if len(parts) == 4 else wheel_name
        tag_triples[tags] = wheel_name

    # Platform definitions from groups of configs
    configurations = {}

    for wheel_name in tag_triples.values():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            # Ignore configurations for unsupported interpreters
            if not supported_python(python_tag):
                continue

            for platform_tag in parsed_wheel.platform_tags:
                # Ignore configurations for unsupported platforms
                if not supported_platform(platform_tag):
                    continue

                for abi_tag in parsed_wheel.abi_tags:
                    # Mirror the abi3 expansion `_whl_install_impl` does
                    # via `compatible_python_tags`, so every triple it
                    # references has a matching config_setting here.
                    for cfg_python_tag in compatible_python_tags(python_tag, abi_tag):
                        # Note that we are NOT filtering out
                        # impossible/unsatisfiable python+abi tag
                        # possibilities. It's not aesthetic but it is
                        # simple enough.
                        configuration = "{}-{}-{}".format(cfg_python_tag, platform_tag, abi_tag)

                        configurations[configuration] = [
                            "@aspect_rules_py//uv/private/constraints/platform:{}".format(platform_tag),
                            "@aspect_rules_py//uv/private/constraints/abi:{}".format(abi_tag),
                            "@aspect_rules_py//uv/private/constraints/python:{}".format(cfg_python_tag),
                        ]

    return configurations

def collect_bdists(lock_data, bdist_specs, wheel_files):
    """Record wheel specs by label and filenames for platform configurations.

    Returns this lock's URL index mapping each wheel URL to its filename and
    download label. Later specs for the same label replace the download metadata.
    """
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):
            name = "whl__%s__%s" % (package["name"], _dist_identifier(bdist))
            label = "@%s//:whl" % name
            url = bdist["url"]
            filename = url_basename(url)
            bdist_specs[label] = (name, filename, bdist)
            bdist_table[url] = (filename, label)
            wheel_files[filename] = True
    return bdist_table

def collect_sdists(lock_id, lock_data, sdist_specs, sdist_table):
    """Record source download specs by repo name and their labels by build key."""
    for package in lock_data.get("package", []):
        if "sdist" in package:
            sdist = package["sdist"]

            sdist_repo_name = "sdist__{}__{}".format(package["name"], _dist_identifier(sdist))
            sdist_specs[sdist_repo_name] = {"file": sdist}

        elif "git" in package["source"]:
            git_url = package["source"]["git"]
            git_cfg = parse_git_url(git_url)
            sdist_repo_name = "sdist_git__{}__{}".format(package["name"], fnv1a_64(git_url))

            sdist_cfg = try_git_to_http_archive(git_cfg)
            if sdist_cfg:
                sdist_specs[sdist_repo_name] = {"file": sdist_cfg}

            else:
                sdist_specs[sdist_repo_name] = {"git": git_cfg}
        else:
            continue

        k = "sdist_build__{}__{}__{}".format(lock_id, package["name"], normalize_version(package["version"]))
        sdist_table[k] = "@{}//file".format(sdist_repo_name)
