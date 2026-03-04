#!/usr/bin/env python3

"""Extract dist-info metadata from a wheel."""

from __future__ import annotations

import argparse
from pathlib import Path
import zipfile


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wheel", required=True)
    parser.add_argument("--dist-info-dir", required=True)
    parser.add_argument("--entry-points-out", required=True)
    return parser


def _dist_info_members(wheel: zipfile.ZipFile) -> tuple[str | None, list[str]]:
    members = [
        name
        for name in wheel.namelist()
        if ".dist-info/" in name and not name.endswith("/")
    ]
    if not members:
        return None, []

    roots = sorted({name.split(".dist-info/", 1)[0] + ".dist-info" for name in members})
    root = roots[0]
    prefix = root + "/"
    return root, [name for name in members if name.startswith(prefix)]


def main() -> None:
    args = _parser().parse_args()

    dist_info_dir = Path(args.dist_info_dir)
    dist_info_dir.mkdir(parents=True, exist_ok=True)

    entry_points_out = Path(args.entry_points_out)
    entry_points_out.parent.mkdir(parents=True, exist_ok=True)
    entry_points_out.write_text("", encoding="utf-8")

    with zipfile.ZipFile(args.wheel) as wheel:
        dist_info_root, members = _dist_info_members(wheel)
        if not dist_info_root:
            return

        prefix = dist_info_root + "/"
        for member in members:
            rel = Path(member[len(prefix):])
            out = dist_info_dir / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(wheel.read(member))

        entry_points_member = prefix + "entry_points.txt"
        if entry_points_member in members:
            entry_points_out.write_bytes(wheel.read(entry_points_member))


if __name__ == "__main__":
    main()
