#!/usr/bin/env python3
"""Map Parser — Shuverse Editor Suite Data Parser.

Parse pret/pokefirered map.json + layout map.bin into a reusable JSON schema.
Stdlib only. Never writes into the decomp tree.
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

DEFAULT_DECOMP = Path("/Users/rumpology/code/repo/32bit/pokefirered")
DEFAULT_OUT_ROOT = Path("/Users/rumpology/code/repo/32bit/pokefred_arm64")
METATILE_PX = 16
MAP_CELL_FMT = "<H"  # little-endian u16
METATILE_ID_MASK = 0x03FF
MAP_ATTR_SHIFT = 10


def name_to_map_id(name: str) -> str:
    """PalletTown_ProfessorOaksLab -> MAP_PALLET_TOWN_PROFESSOR_OAKS_LAB."""
    parts = []
    for segment in name.split("_"):
        s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", segment)
        s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
        parts.append(s.upper())
    return "MAP_" + "_".join(parts)


def list_map_names(decomp: Path) -> list[str]:
    groups_path = decomp / "data" / "maps" / "map_groups.json"
    groups = json.loads(groups_path.read_text(encoding="utf-8"))
    names: list[str] = []
    for key, value in groups.items():
        if key == "group_order":
            continue
        if isinstance(value, list):
            names.extend(value)
    return names


def resolve_map_dir(decomp: Path, query: str) -> Path:
    """Resolve map name or MAP_* id to data/maps/<Name>/."""
    maps_dir = decomp / "data" / "maps"
    direct = maps_dir / query
    if (direct / "map.json").is_file():
        return direct

    q = query.strip()
    q_upper = q.upper()
    names = list_map_names(decomp)

    # Exact folder name (case-sensitive match already failed; try casefold)
    for name in names:
        if name.casefold() == q.casefold():
            return maps_dir / name

    # MAP_* id
    if q_upper.startswith("MAP_"):
        for name in names:
            if name_to_map_id(name) == q_upper:
                return maps_dir / name
        # Fallback: read map.json id fields (handles any naming quirks)
        for name in names:
            mj_path = maps_dir / name / "map.json"
            if not mj_path.is_file():
                continue
            mid = json.loads(mj_path.read_text(encoding="utf-8")).get("id")
            if mid == q_upper:
                return maps_dir / name

    # Bare name that might be missing underscores vs MAP form
    maybe_id = q_upper if q_upper.startswith("MAP_") else name_to_map_id(q)
    for name in names:
        if name_to_map_id(name) == maybe_id:
            return maps_dir / name

    raise FileNotFoundError(
        f"Could not resolve map '{query}' under {maps_dir}. "
        "Try a folder name (PalletTown) or MAP_* id (MAP_PALLET_TOWN)."
    )


def load_layout(decomp: Path, layout_id: str) -> dict:
    layouts_path = decomp / "data" / "layouts" / "layouts.json"
    layouts = json.loads(layouts_path.read_text(encoding="utf-8"))
    for entry in layouts.get("layouts", []):
        if entry and entry.get("id") == layout_id:
            return entry
    raise KeyError(f"Layout '{layout_id}' not found in {layouts_path}")


def parse_map_bin(path: Path) -> tuple[list[int], list[int]]:
    data = path.read_bytes()
    if len(data) % 2 != 0:
        raise ValueError(f"{path}: map.bin size {len(data)} is not a multiple of 2")
    metatile_ids: list[int] = []
    map_attributes: list[int] = []
    for (cell,) in struct.iter_unpack(MAP_CELL_FMT, data):
        metatile_ids.append(cell & METATILE_ID_MASK)
        map_attributes.append(cell >> MAP_ATTR_SHIFT)
    return metatile_ids, map_attributes


def slim_object_event(ev: dict) -> dict:
    """Match pallet_town_parsed.json object_event shape; keep exact field values.

    Clone events (type=clone) omit elevation/movement/script/flag and instead
    reference target_local_id + target_map — pass those through as-is.
    """
    if ev.get("type") == "clone":
        out = {
            "type": "clone",
            "graphics_id": ev["graphics_id"],
            "x": ev["x"],
            "y": ev["y"],
            "target_local_id": ev["target_local_id"],
            "target_map": ev["target_map"],
        }
        if "local_id" in ev:
            out = {"local_id": ev["local_id"], **out}
        return out
    out = {
        "graphics_id": ev["graphics_id"],
        "x": ev["x"],
        "y": ev["y"],
        "elevation": ev["elevation"],
        "movement_type": ev["movement_type"],
        "script": ev["script"],
        "flag": ev["flag"],
    }
    # Clean extension: preserve local_id when present in decomp map.json
    if "local_id" in ev:
        out = {"local_id": ev["local_id"], **out}
    return out


def slim_warp(ev: dict) -> dict:
    return {
        "x": ev["x"],
        "y": ev["y"],
        "elevation": ev["elevation"],
        "dest_map": ev["dest_map"],
        "dest_warp_id": ev["dest_warp_id"],
    }


def slim_coord(ev: dict) -> dict:
    out = {
        "type": ev["type"],
        "x": ev["x"],
        "y": ev["y"],
        "elevation": ev["elevation"],
    }
    # trigger vs weather etc. — pass through known decomp fields without inventing
    for key in ("var", "var_value", "script", "weather"):
        if key in ev:
            out[key] = ev[key]
    return out


def slim_bg(ev: dict) -> dict:
    out = {
        "type": ev["type"],
        "x": ev["x"],
        "y": ev["y"],
        "elevation": ev["elevation"],
    }
    for key in ("player_facing_dir", "script", "item", "flag", "hidden_item_id"):
        if key in ev:
            out[key] = ev[key]
    return out


def slim_connection(conn: dict) -> dict:
    return {
        "map": conn["map"],
        "offset": conn["offset"],
        "direction": conn["direction"],
    }


def parse_map(decomp: Path, map_dir: Path) -> dict:
    map_json = json.loads((map_dir / "map.json").read_text(encoding="utf-8"))
    layout_id = map_json["layout"]
    layout = load_layout(decomp, layout_id)

    width = int(layout["width"])
    height = int(layout["height"])
    blockdata_path = decomp / layout["blockdata_filepath"]
    metatile_ids, map_attributes = parse_map_bin(blockdata_path)

    expected = width * height
    if len(metatile_ids) != expected:
        raise ValueError(
            f"{blockdata_path}: got {len(metatile_ids)} cells, "
            f"expected {expected} ({width}x{height})"
        )

    connections = map_json.get("connections") or []
    object_events = map_json.get("object_events") or []
    warp_events = map_json.get("warp_events") or []
    coord_events = map_json.get("coord_events") or []
    bg_events = map_json.get("bg_events") or []

    return {
        "map_id": map_json["id"],
        "name": map_json["name"],
        "layout_id": layout_id,
        "dimensions": {
            "width_metatiles": width,
            "height_metatiles": height,
            "width_px": width * METATILE_PX,
            "height_px": height * METATILE_PX,
        },
        "tilesets": {
            "primary": layout["primary_tileset"],
            "secondary": layout["secondary_tileset"],
        },
        "music": map_json.get("music"),
        "weather": map_json.get("weather"),
        "map_type": map_json.get("map_type"),
        "connections": [slim_connection(c) for c in connections],
        "object_events": [slim_object_event(e) for e in object_events],
        "warp_events": [slim_warp(e) for e in warp_events],
        "coord_events": [slim_coord(e) for e in coord_events],
        "bg_events": [slim_bg(e) for e in bg_events],
        "blockdata": {
            "encoding": (
                "u16 little-endian; bits0-9 metatile_id, bits10-15 map_attribute"
            ),
            "metatile_ids": metatile_ids,
            "map_attributes": map_attributes,
            "unique_metatile_count": len(set(metatile_ids)),
        },
    }


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Parse a pokefirered map into Shuverse JSON (read-only on decomp)."
    )
    p.add_argument(
        "map",
        help="Map folder name or MAP_* id (e.g. PalletTown, MAP_PALLET_TOWN)",
    )
    p.add_argument(
        "--decomp",
        type=Path,
        default=DEFAULT_DECOMP,
        help=f"pokefirered decomp root (default: {DEFAULT_DECOMP})",
    )
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output JSON path (default: <out-root>/parsed/<MapName>.json)",
    )
    p.add_argument(
        "--out-root",
        type=Path,
        default=DEFAULT_OUT_ROOT,
        help=f"Workspace root for default output (default: {DEFAULT_OUT_ROOT})",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    decomp: Path = args.decomp.resolve()
    if not (decomp / "data" / "maps").is_dir():
        print(f"error: decomp maps dir not found: {decomp / 'data' / 'maps'}", file=sys.stderr)
        return 1

    try:
        map_dir = resolve_map_dir(decomp, args.map)
        parsed = parse_map(decomp, map_dir)
    except (FileNotFoundError, KeyError, ValueError, OSError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    out_path: Path
    if args.out is not None:
        out_path = args.out
    else:
        out_path = args.out_root / "parsed" / f"{parsed['name']}.json"
    out_path = out_path.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(parsed, indent=2) + "\n", encoding="utf-8")

    dims = parsed["dimensions"]
    print(
        f"Wrote {out_path}\n"
        f"  {parsed['name']} ({parsed['map_id']}) "
        f"{dims['width_metatiles']}x{dims['height_metatiles']} "
        f"tilesets={parsed['tilesets']['primary']}+{parsed['tilesets']['secondary']} "
        f"objects={len(parsed['object_events'])} "
        f"warps={len(parsed['warp_events'])} "
        f"coord={len(parsed['coord_events'])} "
        f"bg={len(parsed['bg_events'])} "
        f"connections={len(parsed['connections'])}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
