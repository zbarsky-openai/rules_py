"""Compile a parameter-file batch of first-party Python sources."""

import argparse
import py_compile


def main() -> None:
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("sources", nargs="+")
    sources = iter(parser.parse_args().sources)

    for source, output, stable_source_name in zip(sources, sources, sources, strict=True):
        py_compile.compile(
            source,
            cfile=output,
            dfile=stable_source_name,
            doraise=True,
            # First-party runfiles are editable; validate them for hot reload.
            invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH,
        )


if __name__ == "__main__":
    main()
