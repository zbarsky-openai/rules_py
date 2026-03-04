#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import shlex
import shutil
import sys
from os import chmod, defpath, environ, listdir, makedirs, mkdir, path, pathsep
from subprocess import CalledProcessError, check_call

_DEBUG_FLAG = "-fdebug-default-version=4"
_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

filtered_args = [arg for arg in sys.argv[1:] if arg != "{debug_flag}"]
compiler = os.path.basename(sys.argv[0])
os.execvp(compiler, [compiler] + filtered_args)
""".format(debug_flag = _DEBUG_FLAG)


def _make_compiler_wrapper(tmpdir, name):
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)
    makedirs(path.dirname(wrapper), exist_ok = True)
    with open(wrapper, "w") as f:
        f.write(_COMPILER_WRAPPER)
    chmod(wrapper, 0o755)
    return wrapper


def _override_tool(env, key, wrapper):
    current = env.get(key)
    if not current:
        return
    parts = shlex.split(current)
    if parts:
        parts[0] = wrapper
        env[key] = shlex.join(parts)


def _compiler_env(tmpdir):
    env = dict(environ)
    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        env.get("PATH", defpath),
    ])
    env["TMP"] = tmpdir
    env["TEMP"] = tmpdir
    env["TEMPDIR"] = tmpdir

    cc = _make_compiler_wrapper(tmpdir, "cc")
    cxx = _make_compiler_wrapper(tmpdir, "c++")
    env.setdefault("CC", cc)
    env.setdefault("CXX", cxx)
    env.setdefault("MPICC", _make_compiler_wrapper(tmpdir, "mpicc"))
    env.setdefault("AR", "ar")
    for key, wrapper in [
        ("CC", cc),
        ("CXX", cxx),
        ("CPP", cc),
        ("LDSHARED", cc),
        ("LDCXXSHARED", cxx),
    ]:
        _override_tool(env, key, wrapper)
    return env


PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
opts, args = PARSER.parse_known_args()

tmp_root = opts.outdir.lstrip("/") + ".tmp"
mkdir(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)
build_env = _compiler_env(tmp_root)

try:
    if path.exists(path.join(t, "pyproject.toml")):
        cmd = [
            sys.executable,
            "-m", "build",
            "--wheel",
            "--no-isolation",
            "--outdir", outdir,
        ]
    elif path.exists(path.join(t, "setup.py")):
        cmd = [
            sys.executable,
            path.realpath(path.join(t, "setup.py")),
            "bdist_wheel",
            "--dist-dir",
            outdir,
        ]
    else:
        print("Error: Unable to detect build command! Neither pyproject nor setup.py found!", file=sys.stderr)
        exit(1)

    check_call(cmd, cwd=t, env=build_env)
except CalledProcessError:
    print("Error: Build failed!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print("Error: Built more than one wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)
