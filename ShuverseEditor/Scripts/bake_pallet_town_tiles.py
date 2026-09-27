#!/usr/bin/env python3
"""Bake the Pallet Town sample tileset the editor loads.

Reads a pret/pokefirered checkout:

  data/tilesets/primary/general/
  data/tilesets/secondary/pallet_town/

Writes GBA 4bpp via the pixel_pipeline CLI (see tools/pixel_pipeline/CONTRACT.md)
plus 32-byte RGB555 palette banks. Each bank matches CONTRACT.md's <output.pal>:
c5 = (c8 * 32) >> 8, little-endian 0bbbbbgggggrrrrr. .4bpp matches <output.4bpp>.
metatiles.bin is copied unchanged (8 little-endian screen entries per metatile).
This script shells out to the CLI. It does not link libpixel_pipeline.a.

The gray .pal that pixel_pipeline writes next to tiles.png is the PNG's
own ramp. The editor does not load it. Color comes from the JASC banks.

Usage:
  cd tools/pixel_pipeline && make
  python3 ShuverseEditor/Scripts/bake_pallet_town_tiles.py /path/to/pokefirered
"""

from __future__ import annotations

import hashlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "tools" / "pixel_pipeline" / "build" / "pixel_pipeline"
DESTINATIONS = [
    ROOT / "ShuverseEditor" / "Samples" / "tilesets" / "pallet_town",
    ROOT / "ShuverseEditor" / "App" / "Resources" / "tilesets" / "pallet_town",
]

PRIMARY_TILES = 640
PRIMARY_METATILES = 640


def rgb555(r: int, g: int, b: int) -> int:
    r5 = (r * 32) >> 8
    g5 = (g * 32) >> 8
    b5 = (b * 32) >> 8
    return (r5 & 31) | ((g5 & 31) << 5) | ((b5 & 31) << 10)


def parse_jasc(path: Path) -> bytes:
    lines = path.read_text().splitlines()
    if lines[0] != "JASC-PAL" or int(lines[2]) != 16:
        raise SystemExit(f"{path} is not a 16-color JASC-PAL")
    colors = []
    for line in lines[3:19]:
        r, g, b = (int(part) for part in line.split())
        colors.append(rgb555(r, g, b))
    return struct.pack("<16H", *colors)


def unpack_tiles(blob: bytes) -> list[list[int]]:
    if len(blob) % 32 != 0:
        raise SystemExit(f"4bpp length {len(blob)} is not a multiple of 32")
    tiles = []
    for offset in range(0, len(blob), 32):
        tile = blob[offset : offset + 32]
        pixels = [0] * 64
        for y in range(8):
            for x in range(0, 8, 2):
                byte = tile[y * 4 + x // 2]
                pixels[y * 8 + x] = byte & 0x0F
                pixels[y * 8 + x + 1] = (byte >> 4) & 0x0F
        tiles.append(pixels)
    return tiles


def run_pipeline(png: Path, tiles: Path, pal: Path) -> None:
    if not PIPELINE.is_file():
        raise SystemExit(f"missing {PIPELINE}; run make in tools/pixel_pipeline")
    subprocess.check_call([str(PIPELINE), str(png), str(tiles), str(pal)])


def write_tree(dest: Path, primary_4bpp: bytes, secondary_4bpp: bytes, primary_meta: bytes, secondary_meta: bytes, pals: dict[str, list[bytes]]) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "palettes" / "primary").mkdir(parents=True)
    (dest / "palettes" / "secondary").mkdir(parents=True)
    (dest / "primary.4bpp").write_bytes(primary_4bpp)
    (dest / "secondary.4bpp").write_bytes(secondary_4bpp)
    (dest / "primary.metatiles.bin").write_bytes(primary_meta)
    (dest / "secondary.metatiles.bin").write_bytes(secondary_meta)
    for kind, banks in pals.items():
        for index, bank in enumerate(banks):
            (dest / "palettes" / kind / f"{index:02d}.pal").write_bytes(bank)


def sha256(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def self_check(primary_4bpp: bytes, secondary_4bpp: bytes, primary_meta: bytes, secondary_meta: bytes, primary_pals: list[bytes], secondary_pals: list[bytes]) -> None:
    primary_tiles = unpack_tiles(primary_4bpp)
    secondary_tiles = unpack_tiles(secondary_4bpp)
    if len(primary_tiles) != PRIMARY_TILES:
        raise SystemExit(f"primary tile count {len(primary_tiles)}")
    words = struct.unpack("<8H", primary_meta[28 * 16 : 28 * 16 + 16])
    raw = words[0]
    tile_id = raw & 0x3FF
    pixels = primary_tiles[tile_id]
    # Metatile 28, pixel (5, 0) is tile 41's index 1, primary palette 0.
    if pixels[5] != 1 or tile_id != 41:
        raise SystemExit(f"unexpected metatile 28 corner tile {tile_id} pixel {pixels[5]}")
    bank0 = struct.unpack("<16H", primary_pals[0])
    if bank0[1] != 0x47F7:
        raise SystemExit(f"primary palette 0 color 1 is {bank0[1]:#x}, expected 0x47F7")
    bank11 = struct.unpack("<16H", secondary_pals[11])
    sec_words = struct.unpack("<8H", secondary_meta[(678 - PRIMARY_METATILES) * 16 : (678 - PRIMARY_METATILES) * 16 + 16])
    if (sec_words[0] & 0x3FF) != 641 or (sec_words[0] >> 12) != 11:
        raise SystemExit(f"unexpected metatile 678 entry {sec_words[0]:#x}")
    if bank11[0] == 0:
        raise SystemExit("secondary palette 11 is empty")
    if len(secondary_tiles) < 80:
        raise SystemExit("secondary tileset is shorter than Pallet Town references")


def origin_text(primary_4bpp: bytes, secondary_4bpp: bytes, primary_meta: bytes, secondary_meta: bytes) -> str:
    return f"""Pallet Town sample tiles for the Metal canvas.

Sources (pret/pokefirered):
  data/tilesets/primary/general/tiles.png
  data/tilesets/primary/general/metatiles.bin
  data/tilesets/primary/general/palettes/00.pal … 15.pal
  data/tilesets/secondary/pallet_town/tiles.png
  data/tilesets/secondary/pallet_town/metatiles.bin
  data/tilesets/secondary/pallet_town/palettes/00.pal … 15.pal

Produced by ShuverseEditor/Scripts/bake_pallet_town_tiles.py.

4bpp (pixel_pipeline CLI, CONTRACT.md <output.4bpp>, 32 bytes per 8×8 tile):
  tools/pixel_pipeline/build/pixel_pipeline <tiles.png> primary.4bpp primary.gray.pal
  tools/pixel_pipeline/build/pixel_pipeline <tiles.png> secondary.4bpp secondary.gray.pal
  primary.4bpp   {len(primary_4bpp)} bytes  sha256 {sha256(primary_4bpp)}
  secondary.4bpp {len(secondary_4bpp)} bytes  sha256 {sha256(secondary_4bpp)}

The gray .pal files are the tiles.png ramps (16 grays). They are not copied
here and the editor does not sample them.

RGB555 banks (CONTRACT.md <output.pal>, one 32-byte file per bank):
  palettes/primary/00.pal … 15.pal
  palettes/secondary/00.pal … 15.pal
  c5 = (c8 * 32) >> 8, little-endian 0bbbbbgggggrrrrr, index 0 transparent.

Metatiles (pret, not a pixel_pipeline format):
  primary.metatiles.bin   {len(primary_meta)} bytes  {PRIMARY_METATILES} metatiles
  secondary.metatiles.bin {len(secondary_meta)} bytes
  Each metatile is 8 little-endian u16 screen entries (bottom 2×2, then top 2×2):
    bits 0–9 tile id, bit 10 hflip, bit 11 vflip, bits 12–15 palette.

The canvas places primary tiles at ids 0–639 and secondary tiles at 640+,
and builds BG palettes the way pret does: primary banks 0–6 (color 0 forced
black) and secondary banks 7–12 in slots 7–12.
"""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: bake_pallet_town_tiles.py /path/to/pokefirered")
    pret = Path(sys.argv[1])
    general = pret / "data" / "tilesets" / "primary" / "general"
    pallet = pret / "data" / "tilesets" / "secondary" / "pallet_town"
    work = ROOT / "tools" / "pixel_pipeline" / "build" / "pallet_bake"
    work.mkdir(parents=True, exist_ok=True)
    run_pipeline(general / "tiles.png", work / "primary.4bpp", work / "primary.gray.pal")
    run_pipeline(pallet / "tiles.png", work / "secondary.4bpp", work / "secondary.gray.pal")
    primary_4bpp = (work / "primary.4bpp").read_bytes()
    secondary_4bpp = (work / "secondary.4bpp").read_bytes()
    primary_meta = (general / "metatiles.bin").read_bytes()
    secondary_meta = (pallet / "metatiles.bin").read_bytes()
    if len(primary_meta) != PRIMARY_METATILES * 16:
        raise SystemExit(f"primary metatiles.bin is {len(primary_meta)} bytes")
    primary_pals = [parse_jasc(general / "palettes" / f"{i:02d}.pal") for i in range(16)]
    secondary_pals = [parse_jasc(pallet / "palettes" / f"{i:02d}.pal") for i in range(16)]
    self_check(primary_4bpp, secondary_4bpp, primary_meta, secondary_meta, primary_pals, secondary_pals)
    note = origin_text(primary_4bpp, secondary_4bpp, primary_meta, secondary_meta)
    for dest in DESTINATIONS:
        write_tree(
            dest,
            primary_4bpp,
            secondary_4bpp,
            primary_meta,
            secondary_meta,
            {"primary": primary_pals, "secondary": secondary_pals},
        )
        (dest / "ORIGIN.txt").write_text(note)
        print(f"wrote {dest}")


if __name__ == "__main__":
    main()
