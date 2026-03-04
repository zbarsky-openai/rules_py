#!/usr/bin/env python3

"""Unpack a wheel and apply unified-diff patches to its site-packages tree."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess


_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
_PATCH_METADATA_PREFIXES = (
    "diff --git ",
    "index ",
    "new file mode ",
    "deleted file mode ",
    "old mode ",
    "new mode ",
    "similarity index ",
    "rename from ",
    "rename to ",
)


def _strip_path(path: str, strip: int) -> str | None:
    if path == "/dev/null":
        return None
    parts = path.split("/")
    if strip > len(parts):
        raise ValueError(f"cannot strip {strip} components from {path!r}")
    return "/".join(parts[strip:])


def _parse_patch(path: pathlib.Path) -> list[tuple[str, str, list[tuple[int, list[str]]]]]:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    parsed: list[tuple[str, str, list[tuple[int, list[str]]]]] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("diff --git "):
            index += 1
            continue
        if not line.startswith("--- "):
            index += 1
            continue

        old_path = line[4:].split("\t", 1)[0].strip()
        index += 1
        if index >= len(lines) or not lines[index].startswith("+++ "):
            raise ValueError(f"patch {path} is missing +++ header after {old_path!r}")
        new_path = lines[index][4:].split("\t", 1)[0].strip()
        index += 1

        hunks: list[tuple[int, list[str]]] = []
        while index < len(lines):
            line = lines[index]
            if line.startswith(("diff --git ", "--- ")):
                break
            if line.startswith(_PATCH_METADATA_PREFIXES):
                index += 1
                continue
            if not line.startswith("@@ "):
                index += 1
                continue

            match = _HUNK_RE.match(line.rstrip("\n"))
            if not match:
                raise ValueError(f"unable to parse hunk header {line!r} in {path}")
            old_start = int(match.group(1))
            index += 1
            hunk_lines: list[str] = []
            while index < len(lines):
                line = lines[index]
                if line.startswith(("diff --git ", "--- ", "@@ ")):
                    break
                if line.startswith("\\ No newline at end of file"):
                    index += 1
                    continue
                if line in ("\n", "\r\n"):
                    hunk_lines.append(" " + line)
                    index += 1
                    continue
                if not line or line[0] not in " +-":
                    raise ValueError(f"unsupported patch line {line!r} in {path}")
                hunk_lines.append(line)
                index += 1
            hunks.append((old_start, hunk_lines))

        parsed.append((old_path, new_path, hunks))
    return parsed


def _apply_file_patch(
    root: pathlib.Path,
    old_path: str,
    new_path: str,
    hunks: list[tuple[int, list[str]]],
    *,
    strip: int,
) -> None:
    old_rel = _strip_path(old_path, strip)
    new_rel = _strip_path(new_path, strip)
    target_rel = new_rel or old_rel
    if target_rel is None:
        raise ValueError("patch deletes /dev/null, which is invalid")

    target = root / target_rel
    original_lines = []
    if old_rel and (root / old_rel).exists():
        original_lines = (root / old_rel).read_text(encoding="utf-8").splitlines(keepends=True)

    output: list[str] = []
    cursor = 0
    for old_start, hunk_lines in hunks:
        hunk_start = old_start - 1
        if hunk_start < cursor:
            raise ValueError(f"overlapping hunks while patching {target_rel}")

        output.extend(original_lines[cursor:hunk_start])
        cursor = hunk_start

        for line in hunk_lines:
            prefix = line[:1]
            body = line[1:]
            if prefix == " ":
                if cursor >= len(original_lines) or original_lines[cursor] != body:
                    raise ValueError(f"context mismatch while patching {target_rel}: {body!r}")
                output.append(original_lines[cursor])
                cursor += 1
            elif prefix == "-":
                if cursor >= len(original_lines) or original_lines[cursor] != body:
                    raise ValueError(f"delete mismatch while patching {target_rel}: {body!r}")
                cursor += 1
            elif prefix == "+":
                output.append(body)
            else:
                raise ValueError(f"unsupported hunk line {line!r}")

    output.extend(original_lines[cursor:])

    if new_rel is None:
        target.unlink()
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(output), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--into", required=True)
    parser.add_argument("--patch", action="append", default=[])
    parser.add_argument("--patch-strip", required=True, type=int)
    parser.add_argument("--python-version-major", required=True, type=int)
    parser.add_argument("--python-version-minor", required=True, type=int)
    parser.add_argument("--unpack-tool", required=True)
    parser.add_argument("--wheel", required=True)
    args = parser.parse_args()

    subprocess.run(
        [
            args.unpack_tool,
            "--into",
            args.into,
            "--wheel",
            args.wheel,
            "--python-version-major",
            str(args.python_version_major),
            "--python-version-minor",
            str(args.python_version_minor),
        ],
        check=True,
    )

    site_packages = (
        pathlib.Path(args.into)
        / "lib"
        / f"python{args.python_version_major}.{args.python_version_minor}"
        / "site-packages"
    )
    for patch in args.patch:
        for old_path, new_path, hunks in _parse_patch(pathlib.Path(patch)):
            _apply_file_patch(site_packages, old_path, new_path, hunks, strip=args.patch_strip)


if __name__ == "__main__":
    main()
