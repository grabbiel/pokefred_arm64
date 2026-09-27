#!/usr/bin/env python3
"""Asset Serializer — Shuverse Editor Suite.

Rebuild pret/pokefirered layout map.bin (and optionally map.json / border.bin)
from Map Parser JSON. DEFAULT is --dry-run: never writes into the decomp unless
--write is passed explicitly.

--write reads each target's original bytes, then replaces map.bin, border.bin,
and map.json via atomic rename. If a later file fails, files already replaced
in that map's write set are restored from those originals and the process
exits non-zero naming the failed step.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

DEFAULT_DECOMP = Path("/Users/rumpology/code/repo/32bit/pokefirered")
DEFAULT_WORKSPACE = Path("/Users/rumpology/code/repo/32bit/pokefred_arm64")
MAP_CELL_FMT = "<H"  # little-endian u16
METATILE_ID_MASK = 0x03FF
MAP_ATTR_SHIFT = 10
METATILE_ID_MAX = 1023
MAP_ATTR_MAX = 63
VALID_DIRECTIONS = frozenset({"up", "down", "left", "right"})


class SerializeError(Exception):
    """Fail-closed validation / resolve error."""


def load_layout(decomp: Path, layout_id: str) -> dict:
    layouts_path = decomp / "data" / "layouts" / "layouts.json"
    layouts = json.loads(layouts_path.read_text(encoding="utf-8"))
    for entry in layouts.get("layouts", []):
        if entry and entry.get("id") == layout_id:
            return entry
    raise SerializeError(f"Layout '{layout_id}' not found in {layouts_path}")


def resolve_doc_path(workspace: Path, query: str | Path) -> Path:
    """Resolve path to parsed JSON, map folder name, or MAP_* id under parsed/."""
    q = Path(query)
    if q.is_file():
        return q.resolve()

    # Relative to cwd
    if q.suffix == ".json" and q.exists():
        return q.resolve()

    # Workspace parsed/<Name>.json
    candidates = [
        workspace / "parsed" / f"{query}.json",
        workspace / "parsed" / Path(query).name,
        Path(query),
    ]
    if not str(query).endswith(".json"):
        candidates.insert(0, workspace / "parsed" / f"{query}.json")

    for c in candidates:
        if c.is_file():
            return c.resolve()

    raise SerializeError(
        f"Could not find parsed JSON for '{query}'. "
        f"Tried: {', '.join(str(c) for c in candidates)}"
    )


def pack_map_bin(metatile_ids: list[int], map_attributes: list[int]) -> bytes:
    """Pack cells into little-endian u16 map.bin / border.bin bytes."""
    if len(metatile_ids) != len(map_attributes):
        raise SerializeError(
            f"metatile_ids length {len(metatile_ids)} != "
            f"map_attributes length {len(map_attributes)}"
        )
    out = bytearray()
    for mid, attr in zip(metatile_ids, map_attributes):
        if not (0 <= mid <= METATILE_ID_MAX):
            raise SerializeError(f"metatileId {mid} out of range 0..{METATILE_ID_MAX}")
        if not (0 <= attr <= MAP_ATTR_MAX):
            raise SerializeError(f"mapAttribute {attr} out of range 0..{MAP_ATTR_MAX}")
        cell = (attr << MAP_ATTR_SHIFT) | (mid & METATILE_ID_MASK)
        out += struct.pack(MAP_CELL_FMT, cell)
    return bytes(out)


def unpack_map_bin(data: bytes) -> tuple[list[int], list[int]]:
    """Unpack LE u16 cells into (metatile_ids, map_attributes)."""
    if len(data) % 2 != 0:
        raise SerializeError(f"bin length {len(data)} is not a multiple of 2")
    metatile_ids: list[int] = []
    map_attributes: list[int] = []
    for i in range(0, len(data), 2):
        cell = struct.unpack_from(MAP_CELL_FMT, data, i)[0]
        metatile_ids.append(cell & METATILE_ID_MASK)
        map_attributes.append(cell >> MAP_ATTR_SHIFT)
    return metatile_ids, map_attributes


def resolve_border_arrays(
    doc: dict, layout: dict, border_path: Path
) -> tuple[list[int], list[int], int, int]:
    """Return (metatile_ids, map_attributes, bw, bh) for border.bin.

    Prefer doc['border'] blockdata-style arrays when present; otherwise unpack
    the existing on-disk border.bin (identity round-trip when parser omitted border).
    Size always comes from layouts.json border_width / border_height (pret).
    """
    try:
        bw = int(layout["border_width"])
        bh = int(layout["border_height"])
    except (KeyError, TypeError, ValueError) as e:
        raise SerializeError(
            f"layout missing border_width/border_height: {e}"
        ) from e
    if bw <= 0 or bh <= 0:
        raise SerializeError(f"border dims must be positive, got {bw}x{bh}")
    expected = bw * bh

    border = doc.get("border")
    if isinstance(border, dict) and "metatile_ids" in border and "map_attributes" in border:
        try:
            metatile_ids = [int(x) for x in border["metatile_ids"]]
            map_attributes = [int(x) for x in border["map_attributes"]]
        except (TypeError, ValueError) as e:
            raise SerializeError(f"invalid border arrays: {e}") from e
    elif isinstance(border, list) and border and isinstance(border[0], dict):
        # MapCell-style list: {metatile_id|metatileId, map_attribute|mapAttribute}
        metatile_ids = []
        map_attributes = []
        for i, cell in enumerate(border):
            try:
                mid = int(cell.get("metatile_id", cell.get("metatileId")))
                attr = int(cell.get("map_attribute", cell.get("mapAttribute", 0)))
            except (TypeError, ValueError, AttributeError) as e:
                raise SerializeError(f"border[{i}]: invalid cell ({e})") from e
            metatile_ids.append(mid)
            map_attributes.append(attr)
    else:
        if not border_path.is_file():
            raise SerializeError(
                f"document has no border data and {border_path} is missing"
            )
        on_disk = border_path.read_bytes()
        if len(on_disk) != expected * 2:
            raise SerializeError(
                f"on-disk border.bin size {len(on_disk)} != "
                f"border_width*border_height*2 ({expected * 2}) from layouts.json"
            )
        metatile_ids, map_attributes = unpack_map_bin(on_disk)

    if len(metatile_ids) != expected or len(map_attributes) != expected:
        raise SerializeError(
            f"border cells {len(metatile_ids)}/{len(map_attributes)} != "
            f"border_width*border_height {expected} ({bw}x{bh})"
        )
    return metatile_ids, map_attributes, bw, bh


# Header fields copied from parsed doc → pret map.json (parsed key → json key)
_MAP_JSON_HEADER_FROM_DOC: tuple[tuple[str, str], ...] = (
    ("map_id", "id"),
    ("name", "name"),
    ("layout_id", "layout"),
    ("music", "music"),
    ("weather", "weather"),
    ("map_type", "map_type"),
)

_MAP_JSON_EVENT_KEYS: tuple[str, ...] = (
    "connections",
    "object_events",
    "warp_events",
    "coord_events",
    "bg_events",
)


def _merge_event_list(existing: list | None, incoming: list | None) -> list:
    """Overlay parsed event fields onto existing map.json events; keep unknown keys."""
    base = list(existing) if isinstance(existing, list) else []
    src = list(incoming) if isinstance(incoming, list) else []
    if not src and not base:
        return []
    out: list = []
    for i, new_ev in enumerate(src):
        if not isinstance(new_ev, dict):
            out.append(new_ev)
            continue
        old_ev = base[i] if i < len(base) and isinstance(base[i], dict) else {}
        # Preserve pret key order: start from existing, then overlay parsed fields.
        merged = dict(old_ev)
        for k, v in new_ev.items():
            merged[k] = v
        # If new event introduced keys not in old, append them after old order
        # (dict preserves insertion; overlay above already updates in place).
        # Keys only in new_ev that weren't in old_ev get inserted at end — OK.
        # Re-build to put old keys first, then any brand-new keys:
        ordered: dict = {}
        for k in old_ev:
            if k in merged:
                ordered[k] = merged[k]
        for k, v in new_ev.items():
            if k not in ordered:
                ordered[k] = v
        out.append(ordered)
    return out


def build_map_json(doc: dict, existing: dict | None) -> dict:
    """Rewrite pret map.json from parsed doc while preserving unknown keys."""
    out: dict = dict(existing) if isinstance(existing, dict) else {}

    for doc_key, json_key in _MAP_JSON_HEADER_FROM_DOC:
        if doc_key in doc and doc[doc_key] is not None:
            out[json_key] = doc[doc_key]

    for key in _MAP_JSON_EVENT_KEYS:
        if key not in doc:
            continue
        incoming = doc.get(key)
        prev = out.get(key)
        # pret indoor maps often store "connections": null (not []). Preserve that
        # when the parsed doc has an empty/absent list and nothing to overlay.
        if (
            key == "connections"
            and prev is None
            and (incoming is None or incoming == [])
        ):
            out[key] = None
            continue
        out[key] = _merge_event_list(prev if isinstance(prev, list) else None, incoming)

    return out


def dump_map_json(obj: dict) -> bytes:
    """pret-style map.json: indent=2, trailing newline (byte-stable on reload)."""
    return (json.dumps(obj, indent=2) + "\n").encode("utf-8")


def validate_document(doc: dict) -> tuple[int, int, list[int], list[int]]:
    """Fail-closed validation. Returns (width, height, metatile_ids, map_attributes)."""
    required = ("name", "layout_id", "dimensions", "blockdata")
    for key in required:
        if key not in doc:
            raise SerializeError(f"document missing required key '{key}'")

    dims = doc["dimensions"]
    try:
        width = int(dims["width_metatiles"])
        height = int(dims["height_metatiles"])
    except (KeyError, TypeError, ValueError) as e:
        raise SerializeError(f"invalid dimensions: {e}") from e

    if width <= 0 or height <= 0:
        raise SerializeError(f"dimensions must be positive, got {width}x{height}")

    bd = doc["blockdata"]
    try:
        metatile_ids = [int(x) for x in bd["metatile_ids"]]
        map_attributes = [int(x) for x in bd["map_attributes"]]
    except (KeyError, TypeError, ValueError) as e:
        raise SerializeError(f"invalid blockdata arrays: {e}") from e

    expected = width * height
    if len(metatile_ids) != expected:
        raise SerializeError(
            f"cells.count {len(metatile_ids)} != width*height {expected} "
            f"({width}x{height})"
        )
    if len(map_attributes) != expected:
        raise SerializeError(
            f"map_attributes count {len(map_attributes)} != "
            f"width*height {expected} ({width}x{height})"
        )

    # Event bounds + warp / connection checks (fail closed)
    for i, ev in enumerate(doc.get("object_events") or []):
        # pret border clones may place x/y outside layout bounds
        allow_oob = isinstance(ev, dict) and ev.get("type") == "clone"
        _check_xy(ev, f"object_events[{i}]", width, height, allow_oob=allow_oob)
    for i, ev in enumerate(doc.get("warp_events") or []):
        _check_xy(ev, f"warp_events[{i}]", width, height)
        if "dest_map" not in ev or not isinstance(ev["dest_map"], str):
            raise SerializeError(f"warp_events[{i}]: dest_map must be a string")
        if "dest_warp_id" not in ev:
            raise SerializeError(f"warp_events[{i}]: dest_warp_id required")
        # dest_warp_id is a string in pret map.json (e.g. "0")
        if not isinstance(ev["dest_warp_id"], (str, int)):
            raise SerializeError(f"warp_events[{i}]: dest_warp_id must be str or int")
    for i, ev in enumerate(doc.get("coord_events") or []):
        _check_xy(ev, f"coord_events[{i}]", width, height)
    for i, ev in enumerate(doc.get("bg_events") or []):
        _check_xy(ev, f"bg_events[{i}]", width, height)
    for i, conn in enumerate(doc.get("connections") or []):
        direction = conn.get("direction")
        if direction not in VALID_DIRECTIONS:
            raise SerializeError(
                f"connections[{i}]: direction must be one of "
                f"{sorted(VALID_DIRECTIONS)}, got {direction!r}"
            )
        if "offset" not in conn or not isinstance(conn["offset"], int):
            raise SerializeError(f"connections[{i}]: offset must be an int")

    return width, height, metatile_ids, map_attributes


def _check_xy(
    ev: dict, label: str, width: int, height: int, *, allow_oob: bool = False
) -> None:
    try:
        x = int(ev["x"])
        y = int(ev["y"])
    except (KeyError, TypeError, ValueError) as e:
        raise SerializeError(f"{label}: missing/invalid x,y ({e})") from e
    if allow_oob:
        return
    if not (0 <= x < width and 0 <= y < height):
        raise SerializeError(
            f"{label}: ({x},{y}) outside map bounds 0..{width - 1}, 0..{height - 1}"
        )


def first_diff(a: bytes, b: bytes) -> tuple[int, int | None, int | None] | None:
    """Return (offset, a_byte, b_byte) of first difference, or None if equal."""
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i, a[i], b[i]
    if len(a) != len(b):
        # Differ in length after common prefix
        if len(a) > len(b):
            return n, a[n], None
        return n, None, b[n]
    return None


def git_dirty_paths(repo: Path, paths: list[Path]) -> list[Path]:
    """Return subset of paths that are git-dirty inside repo (tracked or untracked)."""
    dirty: list[Path] = []
    for path in paths:
        try:
            rel = path.resolve().relative_to(repo.resolve())
        except ValueError:
            # Outside repo — treat as not git-managed; skip dirty check
            continue
        # Check status for this path
        r = subprocess.run(
            ["git", "-C", str(repo), "status", "--porcelain", "--", str(rel)],
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode != 0:
            continue
        if r.stdout.strip():
            dirty.append(path)
    return dirty


def atomic_write(target: Path, data: bytes) -> None:
    """Write *.tmp → fsync → rename over target."""
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=target.name + ".", suffix=".tmp", dir=str(target.parent)
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, target)
        # fsync directory for durability (best-effort)
        try:
            dir_fd = os.open(str(target.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
        raise


def _read_original_bytes(path: Path) -> bytes | None:
    """Return file bytes, or None if path does not exist.

    A path that exists but is not a regular file is refused so --write does
    not replace a directory or device node.
    """
    if path.is_file():
        return path.read_bytes()
    if path.exists():
        raise SerializeError(
            f"--write failed at step 'read original' ({path}): "
            "exists but is not a regular file; no files overwritten"
        )
    return None


def _format_write_failure(
    step: str,
    path: Path,
    exc: BaseException,
    restored: list[str],
    removed: list[str],
    rollback_failed: list[tuple[str, Path, BaseException]],
) -> str:
    parts = [f"--write failed at step '{step}' ({path}): {exc}"]
    if restored:
        parts.append("restored prior files: " + ", ".join(restored))
    if removed:
        parts.append(
            "removed files that did not exist before this write: "
            + ", ".join(removed)
        )
    if rollback_failed:
        details = "; ".join(
            f"{name} ({failed_path}): {err}"
            for name, failed_path, err in rollback_failed
        )
        parts.append("rollback failed for " + details)
    if not restored and not removed and not rollback_failed:
        parts.append("no files overwritten")
    return "; ".join(parts)


def write_map_set(
    steps: list[tuple[str, Path, bytes]],
    *,
    writer: Callable[[Path, bytes], None] = atomic_write,
) -> None:
    """Replace each (step name, path, bytes) via ``writer`` (default atomic_write).

    Originals are read into memory before any replace. If a later step fails,
    files already overwritten are restored by calling ``writer`` with those
    saved bytes. A file that did not exist beforehand is removed. Raises
    SerializeError naming the failed step. Rollback of one file does not
    cancel attempts to restore the others.
    """
    originals: dict[Path, bytes | None] = {}
    for label, path, _data in steps:
        if path in originals:
            continue
        try:
            originals[path] = _read_original_bytes(path)
        except OSError as e:
            raise SerializeError(
                f"--write failed at step 'read original {label}' ({path}): {e}; "
                "no files overwritten"
            ) from e

    written: list[tuple[str, Path]] = []
    for label, path, data in steps:
        print(f"  writing {label} ({len(data)} bytes) ...", flush=True)
        try:
            writer(path, data)
        except Exception as e:
            restored, removed, rollback_failed = _rollback_written(
                written, originals, writer
            )
            raise SerializeError(
                _format_write_failure(
                    label, path, e, restored, removed, rollback_failed
                )
            ) from e
        written.append((label, path))
        print(f"  wrote {path}", flush=True)


def _rollback_written(
    written: list[tuple[str, Path]],
    originals: dict[Path, bytes | None],
    writer: Callable[[Path, bytes], None],
) -> tuple[list[str], list[str], list[tuple[str, Path, BaseException]]]:
    """Restore files already replaced. Reverse order; each path at most once."""
    restored: list[str] = []
    removed: list[str] = []
    failed: list[tuple[str, Path, BaseException]] = []
    seen: set[Path] = set()
    for step_label, path in reversed(written):
        if path in seen:
            continue
        seen.add(path)
        original = originals[path]
        try:
            if original is None:
                path.unlink(missing_ok=True)
                removed.append(step_label)
                print(
                    f"  removed {path} (did not exist before this write)",
                    flush=True,
                )
            else:
                writer(path, original)
                restored.append(step_label)
                print(f"  restored {path}", flush=True)
        except Exception as err:
            failed.append((step_label, path, err))
            print(
                f"  rollback failed for {path}: {err}",
                file=sys.stderr,
                flush=True,
            )
    return restored, removed, failed


def slim_compare_events(doc: dict, map_json: dict) -> list[str]:
    """Semantic event comparison (order-sensitive lists; field subset from parser).

    Returns list of human-readable mismatch notes (empty = match).
    """
    notes: list[str] = []

    def count(key: str) -> tuple[int, int]:
        a = doc.get(key) or []
        b = map_json.get(key) or []
        return len(a), len(b)

    for key in ("object_events", "warp_events", "coord_events", "bg_events", "connections"):
        a_n, b_n = count(key)
        if a_n != b_n:
            notes.append(f"{key}: parsed has {a_n}, map.json has {b_n}")

    # Spot-check warps (critical round-trip fields)
    warps_a = doc.get("warp_events") or []
    warps_b = map_json.get("warp_events") or []
    for i, (a, b) in enumerate(zip(warps_a, warps_b)):
        for field in ("x", "y", "elevation", "dest_map", "dest_warp_id"):
            if str(a.get(field)) != str(b.get(field)):
                notes.append(
                    f"warp_events[{i}].{field}: parsed={a.get(field)!r} "
                    f"map.json={b.get(field)!r}"
                )

    conns_a = doc.get("connections") or []
    conns_b = map_json.get("connections") or []
    for i, (a, b) in enumerate(zip(conns_a, conns_b)):
        for field in ("map", "offset", "direction"):
            if a.get(field) != b.get(field):
                notes.append(
                    f"connections[{i}].{field}: parsed={a.get(field)!r} "
                    f"map.json={b.get(field)!r}"
                )

    return notes


def serialize_one(
    decomp: Path,
    doc: dict,
    *,
    do_write: bool,
    force: bool,
) -> int:
    """Serialize one document. Returns 0 on success (match / write OK), 1 on mismatch/error."""
    width, height, metatile_ids, map_attributes = validate_document(doc)
    packed = pack_map_bin(metatile_ids, map_attributes)

    layout = load_layout(decomp, doc["layout_id"])
    # Sanity: layout dimensions should agree
    lw, lh = int(layout["width"]), int(layout["height"])
    if (lw, lh) != (width, height):
        raise SerializeError(
            f"document dims {width}x{height} != layout {doc['layout_id']} {lw}x{lh}"
        )

    map_bin_path = decomp / layout["blockdata_filepath"]
    border_path = decomp / layout["border_filepath"]
    map_json_path = decomp / "data" / "maps" / doc["name"] / "map.json"

    expected_size = width * height * 2
    if len(packed) != expected_size:
        raise SerializeError(
            f"packed size {len(packed)} != expected {expected_size}"
        )

    border_ids, border_attrs, bw, bh = resolve_border_arrays(doc, layout, border_path)
    border_packed = pack_map_bin(border_ids, border_attrs)
    border_expected = bw * bh * 2
    if len(border_packed) != border_expected:
        raise SerializeError(
            f"border packed size {len(border_packed)} != expected {border_expected}"
        )

    existing_map_json: dict | None = None
    if map_json_path.is_file():
        existing_map_json = json.loads(map_json_path.read_text(encoding="utf-8"))
    rebuilt_map_json = build_map_json(doc, existing_map_json)
    map_json_bytes = dump_map_json(rebuilt_map_json)

    print(f"map: {doc['name']} ({doc.get('map_id', '?')})")
    print(f"  layout: {doc['layout_id']}")
    print(f"  dims:   {width}x{height} ({expected_size} bytes)")
    print(f"  border: {bw}x{bh} ({border_expected} bytes)")
    print(f"  target: {map_bin_path}")
    print(f"  border: {border_path}")
    print(f"  json:   {map_json_path}")

    all_match = True

    # --- map.bin ---
    if not map_bin_path.is_file():
        print("  map.bin: MISSING on disk")
        all_match = False
    else:
        on_disk = map_bin_path.read_bytes()
        diff = first_diff(packed, on_disk)
        if diff is None:
            print(f"  map.bin: MATCH ({len(on_disk)} bytes, byte-identical)")
        else:
            all_match = False
            off, a_b, b_b = diff
            print(
                f"  map.bin: DIFF  rebuilt={len(packed)} disk={len(on_disk)} "
                f"first_diff_offset={off} "
                f"rebuilt_byte={a_b if a_b is None else f'0x{a_b:02x}'} "
                f"disk_byte={b_b if b_b is None else f'0x{b_b:02x}'}"
            )
            if off < min(len(packed), len(on_disk)):
                cell_i = off // 2
                rb = struct.unpack_from(MAP_CELL_FMT, packed, cell_i * 2)[0]
                db = struct.unpack_from(MAP_CELL_FMT, on_disk, cell_i * 2)[0]
                print(
                    f"           cell[{cell_i}]: rebuilt=0x{rb:04x} "
                    f"(id={rb & METATILE_ID_MASK} attr={rb >> MAP_ATTR_SHIFT}) "
                    f"disk=0x{db:04x} "
                    f"(id={db & METATILE_ID_MASK} attr={db >> MAP_ATTR_SHIFT})"
                )

    # --- border.bin ---
    if not border_path.is_file():
        print("  border.bin: MISSING on disk")
        all_match = False
    else:
        border_disk = border_path.read_bytes()
        bdiff = first_diff(border_packed, border_disk)
        if bdiff is None:
            print(f"  border.bin: MATCH ({len(border_disk)} bytes, byte-identical)")
        else:
            all_match = False
            off, a_b, b_b = bdiff
            print(
                f"  border.bin: DIFF  rebuilt={len(border_packed)} "
                f"disk={len(border_disk)} first_diff_offset={off} "
                f"rebuilt_byte={a_b if a_b is None else f'0x{a_b:02x}'} "
                f"disk_byte={b_b if b_b is None else f'0x{b_b:02x}'}"
            )

    # --- map.json ---
    if existing_map_json is None:
        print(f"  map.json: MISSING ({map_json_path})")
        all_match = False
    else:
        on_disk_json = map_json_path.read_bytes()
        if map_json_bytes == on_disk_json:
            print(f"  map.json: MATCH ({len(on_disk_json)} bytes, byte-identical)")
        else:
            # Prefer byte-identical; fall back to semantic + note order/whitespace
            notes = slim_compare_events(doc, existing_map_json)
            # Also compare rebuilt vs existing semantically (full dump round-trip)
            if notes:
                all_match = False
                print(f"  map.json: DIFF semantic ({len(notes)} note(s)):")
                for n in notes[:10]:
                    print(f"    - {n}")
                if len(notes) > 10:
                    print(f"    ... and {len(notes) - 10} more")
            else:
                # Semantic event match but bytes differ (key order / whitespace)
                print(
                    f"  map.json: SEMANTIC MATCH but bytes differ "
                    f"(rebuilt={len(map_json_bytes)} disk={len(on_disk_json)}; "
                    f"key order/whitespace)"
                )
                # Still count as match for dry-run exit; write will rewrite
                # Callers that need strict bytes should cmp after --write.
                all_match = all_match and True

    if not do_write:
        print("  mode: dry-run (no writes)")
        return 0 if all_match else 1

    # Write path: map.bin + border.bin + map.json
    targets = [map_bin_path, border_path, map_json_path]
    dirty = git_dirty_paths(decomp, targets)
    if dirty and not force:
        print("error: refusing to write; git-dirty targets (pass --force to override):")
        for p in dirty:
            print(f"  {p}")
        return 1

    # One map's write set. Originals are snapshotted inside write_map_set;
    # a failure after any successful replace restores those prior bytes.
    write_map_set(
        [
            ("map.bin", map_bin_path, packed),
            ("border.bin", border_path, border_packed),
            ("map.json", map_json_path, map_json_bytes),
        ]
    )
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Serialize Shuverse parsed map JSON back to pokefirered "
            "map.bin / border.bin / map.json. "
            "Dry-run is the DEFAULT; pass --write to actually modify the decomp."
        )
    )
    p.add_argument(
        "doc",
        nargs="?",
        default=None,
        help="Parsed JSON path, map folder name, or MAP_* (e.g. PalletTown, parsed/PalletTown.json)",
    )
    p.add_argument(
        "--doc",
        dest="doc_flag",
        default=None,
        help="Same as positional doc (alternate form)",
    )
    p.add_argument(
        "--decomp",
        type=Path,
        default=DEFAULT_DECOMP,
        help=f"pokefirered decomp root (default: {DEFAULT_DECOMP})",
    )
    p.add_argument(
        "--workspace",
        type=Path,
        default=DEFAULT_WORKSPACE,
        help=f"Shuverse workspace root for resolving map names (default: {DEFAULT_WORKSPACE})",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Compare only; never write (DEFAULT)",
    )
    p.add_argument(
        "--write",
        action="store_true",
        default=False,
        help="Actually write map.bin, border.bin, and map.json (disables dry-run)",
    )
    p.add_argument(
        "--force",
        action="store_true",
        default=False,
        help="Allow writing even if target paths are git-dirty",
    )
    p.add_argument(
        "--self-check",
        action="store_true",
        default=False,
        help=(
            "Pack/unpack synthetic blockdata and drill cross-file --write "
            "rollback in a temp directory. No decomp checkout required."
        ),
    )
    return p


def run_self_check() -> int:
    """Decomp-free pack/unpack identity plus the cross-file rollback drill.

    This does not replace the PalletTown / OaksLab byte-identity ``--write``
    gate, which needs a local pokefirered checkout.
    """
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if cond:
            print(f"self-check: {name} OK", flush=True)
            return
        msg = f"self-check: {name} FAILED"
        if detail:
            msg = f"{msg} ({detail})"
        print(msg, file=sys.stderr, flush=True)
        failures.append(msg)

    ids = [0, 1, 1023, 42]
    attrs = [0, 1, 63, 7]
    try:
        packed = pack_map_bin(ids, attrs)
        got_ids, got_attrs = unpack_map_bin(packed)
        check(
            "pack/unpack synthetic blockdata",
            got_ids == ids and got_attrs == attrs and len(packed) == 8,
            f"got ids={got_ids} attrs={got_attrs} len={len(packed)}",
        )
        cell = struct.unpack_from(MAP_CELL_FMT, packed, 4)[0]
        check(
            "cell packing (attr<<10)|id",
            cell == ((63 << MAP_ATTR_SHIFT) | 1023),
            f"cell=0x{cell:04x}",
        )
    except SerializeError as e:
        check("pack/unpack synthetic blockdata", False, str(e))

    try:
        pack_map_bin([METATILE_ID_MAX + 1], [0])
        check("reject metatileId 1024", False, "no error")
    except SerializeError:
        check("reject metatileId 1024", True)

    try:
        pack_map_bin([0], [MAP_ATTR_MAX + 1])
        check("reject mapAttribute 64", False, "no error")
    except SerializeError:
        check("reject mapAttribute 64", True)

    try:
        unpack_map_bin(b"\x00")
        check("reject odd bin length", False, "no error")
    except SerializeError:
        check("reject odd bin length", True)

    with tempfile.TemporaryDirectory(prefix="serialize-map-selfcheck-") as tmp:
        root = Path(tmp)
        map_bin = root / "map.bin"
        border_bin = root / "border.bin"
        map_json = root / "map.json"
        old_map = b"OLD-MAP"
        old_border = b"OLD-BORDER"
        old_json = b'{"id":"OLD"}\n'
        new_map = b"NEW-MAP-BYTES"
        new_border = b"NEW-BORDER-BYTES"
        new_json = b'{"id":"NEW"}\n'
        map_bin.write_bytes(old_map)
        border_bin.write_bytes(old_border)
        map_json.write_bytes(old_json)

        seen: list[tuple[str, bytes]] = []

        def fail_on_json(path: Path, data: bytes) -> None:
            if path.name == "map.json" and data == new_json:
                raise OSError("injected map.json failure")
            atomic_write(path, data)
            seen.append((path.name, data))

        try:
            write_map_set(
                [
                    ("map.bin", map_bin, new_map),
                    ("border.bin", border_bin, new_border),
                    ("map.json", map_json, new_json),
                ],
                writer=fail_on_json,
            )
            check("rollback after map.json failure", False, "write_map_set returned")
        except SerializeError as e:
            msg = str(e)
            check(
                "rollback after map.json failure",
                "map.json" in msg
                and "injected map.json failure" in msg
                and "restored prior files: border.bin, map.bin" in msg
                and map_bin.read_bytes() == old_map
                and border_bin.read_bytes() == old_border
                and map_json.read_bytes() == old_json
                and (map_bin.name, new_map) in seen
                and (border_bin.name, new_border) in seen
                and (border_bin.name, old_border) in seen
                and (map_bin.name, old_map) in seen,
                msg,
            )

        # First step fails before any replace.
        map_bin.write_bytes(old_map)

        def fail_first(path: Path, data: bytes) -> None:
            raise OSError("injected map.bin failure")

        try:
            write_map_set(
                [("map.bin", map_bin, new_map)],
                writer=fail_first,
            )
            check("first-step failure leaves original", False, "write_map_set returned")
        except SerializeError as e:
            msg = str(e)
            check(
                "first-step failure leaves original",
                "step 'map.bin'" in msg
                and "no files overwritten" in msg
                and map_bin.read_bytes() == old_map,
                msg,
            )

        # border.bin did not exist; a later failure must remove it.
        border_bin.unlink()
        map_bin.write_bytes(old_map)
        map_json.write_bytes(old_json)

        def fail_json_only(path: Path, data: bytes) -> None:
            if path.name == "map.json":
                raise OSError("injected map.json failure")
            atomic_write(path, data)

        try:
            write_map_set(
                [
                    ("map.bin", map_bin, new_map),
                    ("border.bin", border_bin, new_border),
                    ("map.json", map_json, new_json),
                ],
                writer=fail_json_only,
            )
            check("remove file that did not exist", False, "write_map_set returned")
        except SerializeError as e:
            msg = str(e)
            check(
                "remove file that did not exist",
                "removed files that did not exist before this write: border.bin" in msg
                and "restored prior files: map.bin" in msg
                and map_bin.read_bytes() == old_map
                and not border_bin.exists()
                and map_json.read_bytes() == old_json,
                msg,
            )

        # Restore of border.bin fails; map.bin must still be put back.
        border_bin.write_bytes(old_border)
        map_bin.write_bytes(old_map)
        map_json.write_bytes(old_json)

        def fail_json_and_border_restore(path: Path, data: bytes) -> None:
            if path.name == "map.json" and data == new_json:
                raise OSError("injected map.json failure")
            if path.name == "border.bin" and data == old_border:
                raise OSError("injected border.bin rollback failure")
            atomic_write(path, data)

        try:
            write_map_set(
                [
                    ("map.bin", map_bin, new_map),
                    ("border.bin", border_bin, new_border),
                    ("map.json", map_json, new_json),
                ],
                writer=fail_json_and_border_restore,
            )
            check("partial rollback reports both outcomes", False, "write_map_set returned")
        except SerializeError as e:
            msg = str(e)
            check(
                "partial rollback reports both outcomes",
                "step 'map.json'" in msg
                and "restored prior files: map.bin" in msg
                and "rollback failed for border.bin" in msg
                and "injected border.bin rollback failure" in msg
                and map_bin.read_bytes() == old_map
                and border_bin.read_bytes() == new_border
                and map_json.read_bytes() == old_json,
                msg,
            )

    if failures:
        print(f"self-check: {len(failures)} failed", file=sys.stderr)
        return 1
    print("self-check: passed")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.self_check:
        return run_self_check()
    query = args.doc_flag or args.doc
    if not query:
        print("error: provide a map name or --doc path to parsed JSON", file=sys.stderr)
        return 1

    decomp: Path = args.decomp.resolve()
    workspace: Path = args.workspace.resolve()
    if not (decomp / "data" / "layouts").is_dir():
        print(
            f"error: decomp layouts dir not found: {decomp / 'data' / 'layouts'}",
            file=sys.stderr,
        )
        return 1

    do_write = bool(args.write)
    # --write overrides default dry-run
    if do_write:
        print("warning: --write enabled; will modify decomp files")

    try:
        doc_path = resolve_doc_path(workspace, query)
        doc = json.loads(doc_path.read_text(encoding="utf-8"))
        print(f"loaded: {doc_path}")
        return serialize_one(decomp, doc, do_write=do_write, force=args.force)
    except SerializeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
