#!/usr/bin/env python3
"""Extract MapShaders.source and typecheck it with the macOS Metal compiler."""

import pathlib
import shutil
import subprocess
import sys


def extract_source(swift_text: str) -> str:
    marker = 'static let source = """'
    start = swift_text.index(marker) + len(marker)
    if swift_text[start:start + 1] == "\n":
        start += 1
    end = swift_text.index('\n    """', start)
    body = swift_text[start:end]
    lines = body.split("\n")
    indents = [len(line) - len(line.lstrip(" ")) for line in lines if line.strip()]
    trim = min(indents) if indents else 0
    dedented = []
    for line in lines:
        if line.startswith(" " * trim):
            dedented.append(line[trim:])
        else:
            dedented.append(line)
    return "\n".join(dedented) + "\n"


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    swift_path = root / "App" / "MapShaders.swift"
    source = extract_source(swift_path.read_text())
    for needle in (
        "vertex Varying map_vertex",
        "[[stage_in]]",
        "kernel void map_tile_overlay",
        "imageblock<TilePixel>",
    ):
        if needle not in source:
            sys.exit(f"extracted Metal is missing {needle!r}")
    if source.startswith(" ") or source.startswith("\n"):
        sys.exit("extracted Metal still has a leading indent or blank line")

    out = pathlib.Path("/tmp/ShuverseMapShaders.metal")
    air = pathlib.Path("/tmp/ShuverseMapShaders.air")
    out.write_text(source)
    if shutil.which("xcrun") is None:
        sys.exit("xcrun is required to compile MapShaders")
    subprocess.check_call(
        [
            "xcrun",
            "-sdk",
            "macosx",
            "metal",
            "-c",
            str(out),
            "-o",
            str(air),
            "-std=macos-metal2.4",
        ]
    )
    print(f"compiled {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
