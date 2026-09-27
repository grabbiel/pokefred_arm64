#!/usr/bin/env python3
"""AST Parser understanding pipeline — parse all maps, dry-run serialize, status JSON.

Stdlib only. Never writes into the decomp tree (serialize always dry-run).
Owns parse_map / parsed/ only; Serializer issues are recorded as open_issues.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

# Local tools (same directory)
TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import parse_map as pm  # noqa: E402
import serialize_map as sm  # noqa: E402

DEFAULT_DECOMP = Path("/Users/rumpology/code/repo/32bit/pokefirered")
DEFAULT_WORKSPACE = Path("/Users/rumpology/code/repo/32bit/pokefred_arm64")
LIMA = ZoneInfo("America/Lima")


def now_iso_lima() -> str:
    return datetime.now(LIMA).isoformat(timespec="seconds")


def list_all_maps(decomp: Path) -> list[str]:
    return pm.list_map_names(decomp)


def parse_all(
    decomp: Path, workspace: Path, names: list[str]
) -> tuple[list[str], list[dict]]:
    """Parse every map into workspace/parsed/<Name>.json. Returns (ok_names, fails)."""
    out_dir = workspace / "parsed"
    out_dir.mkdir(parents=True, exist_ok=True)
    ok: list[str] = []
    fails: list[dict] = []
    for name in names:
        try:
            map_dir = pm.resolve_map_dir(decomp, name)
            parsed = pm.parse_map(decomp, map_dir)
            out_path = out_dir / f"{parsed['name']}.json"
            out_path.write_text(json.dumps(parsed, indent=2) + "\n", encoding="utf-8")
            ok.append(parsed["name"])
        except Exception as e:  # noqa: BLE001 — batch collect
            fails.append({"map": name, "error": f"{type(e).__name__}: {e}"})
    return ok, fails


def serialize_dry_run_all(
    decomp: Path, workspace: Path, names: list[str]
) -> tuple[list[str], list[dict]]:
    """Dry-run serialize for each parsed JSON. Returns (ok_names, fails)."""
    ok: list[str] = []
    fails: list[dict] = []
    for name in names:
        doc_path = workspace / "parsed" / f"{name}.json"
        if not doc_path.is_file():
            fails.append({"map": name, "error": "parsed JSON missing"})
            continue
        try:
            doc = json.loads(doc_path.read_text(encoding="utf-8"))
            # Quiet path: validate + pack + byte-compare (no --write)
            width, height, metatile_ids, map_attributes = sm.validate_document(doc)
            packed = sm.pack_map_bin(metatile_ids, map_attributes)
            layout = sm.load_layout(decomp, doc["layout_id"])
            lw, lh = int(layout["width"]), int(layout["height"])
            if (lw, lh) != (width, height):
                raise sm.SerializeError(
                    f"document dims {width}x{height} != layout "
                    f"{doc['layout_id']} {lw}x{lh}"
                )
            map_bin_path = decomp / layout["blockdata_filepath"]
            if not map_bin_path.is_file():
                raise sm.SerializeError(f"map.bin missing: {map_bin_path}")
            on_disk = map_bin_path.read_bytes()
            diff = sm.first_diff(packed, on_disk)
            if diff is not None:
                off, a_b, b_b = diff
                raise sm.SerializeError(
                    f"map.bin DIFF offset={off} rebuilt={a_b!r} disk={b_b!r}"
                )
            ok.append(name)
        except Exception as e:  # noqa: BLE001
            fails.append({"map": name, "error": f"{type(e).__name__}: {e}"})
    return ok, fails


def classify_open_issues(
    parse_fails: list[dict], serialize_fails: list[dict]
) -> list[dict]:
    """Turn fail lists into open_issues with ownership hints."""
    issues: list[dict] = []

    if parse_fails:
        issues.append(
            {
                "id": "parse_failures",
                "maps": [f["map"] for f in parse_fails],
                "summary": (
                    f"{len(parse_fails)} map(s) failed parse_map. "
                    f"First: {parse_fails[0]['map']}: {parse_fails[0]['error']}"
                ),
                "owner": "AST-Parser",
                "details": parse_fails[:20],
            }
        )

    # Group serialize fails by error signature
    by_sig: dict[str, list[dict]] = {}
    for f in serialize_fails:
        # Normalize: strip map-specific paths somewhat
        sig = f["error"].split(":")[0]
        if "outside map bounds" in f["error"]:
            sig = "SerializeError: event OOB (non-clone?)"
        elif "map.bin DIFF" in f["error"]:
            sig = "SerializeError: map.bin DIFF"
        elif "map.bin missing" in f["error"]:
            sig = "SerializeError: map.bin missing"
        elif "parsed JSON missing" in f["error"]:
            sig = "SerializeError: parsed JSON missing"
        by_sig.setdefault(sig, []).append(f)

    for sig, group in by_sig.items():
        owner = "Serializer"
        issue_id = "serialize_" + sig.split(":")[0].lower().replace(" ", "_")
        if "OOB" in sig:
            issue_id = "serialize_event_oob"
            owner = "Serializer"
            summary = (
                f"{len(group)} map(s) fail serialize dry-run on event bounds. "
                "If these are pret border clones, ensure type=='clone' is preserved "
                "by parse_map and allowlisted in serialize_map (already present for "
                "type==clone). Recommend Serializer review if non-clone OOB; "
                "AST-Parser should verify clone slim_object_event pass-through."
            )
        elif "DIFF" in sig:
            issue_id = "serialize_map_bin_diff"
            owner = "AST-Parser|Serializer"
            summary = (
                f"{len(group)} map(s) rebuild map.bin differently from disk. "
                "Check metatile/attr packing endianness and layout path resolution."
            )
        elif "parsed JSON missing" in sig:
            issue_id = "serialize_missing_parsed"
            owner = "AST-Parser"
            summary = f"{len(group)} map(s) had no parsed JSON (parse failed upstream)."
        else:
            summary = f"{len(group)} map(s): {sig}. First: {group[0]['map']}: {group[0]['error']}"

        issues.append(
            {
                "id": issue_id,
                "maps": [g["map"] for g in group],
                "summary": summary,
                "owner": owner,
                "details": group[:20],
            }
        )

    return issues


def build_status(
    *,
    total: int,
    parse_ok: list[str],
    parse_fail: list[dict],
    serialize_ok: list[str],
    serialize_fail: list[dict],
    open_issues: list[dict],
    script_slice: dict | None,
    last_run_iso: str,
) -> dict:
    return {
        "total_maps": total,
        "parse_ok": len(parse_ok),
        "parse_fail": len(parse_fail),
        "serialize_ok": len(serialize_ok),
        "serialize_fail": len(serialize_fail),
        "last_run_iso": last_run_iso,
        "open_issues": [
            {k: v for k, v in issue.items() if k != "details"} | (
                {"detail_count": len(issue.get("details") or [])}
                if "details" in issue
                else {}
            )
            for issue in open_issues
        ],
        # Full fail samples kept for machine follow-up
        "parse_fail_samples": parse_fail[:30],
        "serialize_fail_samples": serialize_fail[:30],
        "open_issues_full": open_issues,
        "script_slice": script_slice or {},
        "notes": (
            "Serialize always dry-run (no decomp writes). "
            "serialize_ok = packed map.bin byte-identity vs decomp disk only "
            "(validate_document + pack_map_bin); does NOT mean map.json events/"
            "scripts were rewritten or slim_compare_events passed. "
            "Clone OOB allowlist lives in serialize_map.validate_document "
            "(type=='clone'). Pipeline owns parse + status only. "
            "serialize_map --write stays fail-closed (refuses git-dirty targets "
            "without --force) and is Serializer-owned — this pipeline never passes --write."
        ),
    }


def run_cycle(
    decomp: Path,
    workspace: Path,
    *,
    skip_parse: bool = False,
    skip_serialize: bool = False,
) -> dict:
    names = list_all_maps(decomp)
    last_run = now_iso_lima()

    if skip_parse:
        parse_ok = sorted(
            p.stem for p in (workspace / "parsed").glob("*.json") if p.stem != "understanding_status" and not p.name.endswith(".scripts.json")
        )
        # Prefer map_groups order intersection
        name_set = set(names)
        parse_ok = [n for n in names if n in name_set and (workspace / "parsed" / f"{n}.json").is_file()]
        parse_fail = [
            {"map": n, "error": "skipped parse; JSON missing"}
            for n in names
            if not (workspace / "parsed" / f"{n}.json").is_file()
        ]
    else:
        parse_ok, parse_fail = parse_all(decomp, workspace, names)

    if skip_serialize:
        serialize_ok, serialize_fail = [], []
    else:
        # Only dry-run maps we successfully parsed
        serialize_ok, serialize_fail = serialize_dry_run_all(decomp, workspace, parse_ok)

    open_issues = classify_open_issues(parse_fail, serialize_fail)

    # Discover additive script coverage (written by tools/parse_scripts.py; parsed/ is local)
    import parse_scripts as ps  # noqa: E402 — same tools/ dir already on path

    script_maps = ps.list_script_maps(workspace)
    script_slice = {
        "maps": script_maps,
        "count": len(script_maps),
        "corridor_preset": list(ps.CORRIDOR_MAPS),
        "cerulean_cluster_preset": list(ps.CERULEAN_CLUSTER_MAPS),
        "vermilion_cluster_preset": list(ps.VERMILION_CLUSTER_MAPS),
        "lavender_cluster_preset": list(ps.LAVENDER_CLUSTER_MAPS),
        "script_coverage_preset": list(ps.SCRIPT_COVERAGE_MAPS),
        "note": (
            "Additive *.scripts.json via tools/parse_scripts.py (stdlib). "
            "parsed/ is workspace-local / gitignored by Workspace I/O — regenerate with "
            "`python3 tools/parse_scripts.py --script-coverage` after parse_map. "
            "Shared labels (EventScript_CutTree, etc.) resolve under data/scripts/*.inc. "
            "Does not mutate map JSON schema."
        ),
        "prototype": "tools/parse_scripts.py → parsed/<Map>.scripts.json",
        "re_run": (
            "python3 tools/parse_scripts.py --script-coverage && "
            "python3 tools/understanding_pipeline.py --skip-parse"
        ),
    }

    status = build_status(
        total=len(names),
        parse_ok=parse_ok,
        parse_fail=parse_fail,
        serialize_ok=serialize_ok,
        serialize_fail=serialize_fail,
        open_issues=open_issues,
        script_slice=script_slice,
        last_run_iso=last_run,
    )

    out = workspace / "parsed" / "understanding_status.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    # Slim file for consumers: drop open_issues_full details bloat optionally kept
    out.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    return status


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Parse all maps + serialize dry-run; write understanding_status.json")
    p.add_argument("--decomp", type=Path, default=DEFAULT_DECOMP)
    p.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE)
    p.add_argument("--skip-parse", action="store_true", help="Reuse existing parsed/*.json")
    p.add_argument("--skip-serialize", action="store_true")
    p.add_argument(
        "--scripts-coverage",
        action="store_true",
        help="Also refresh all script-coverage presets (slices 1–4 union) via parse_scripts",
    )
    p.add_argument(
        "--scripts-corridor",
        action="store_true",
        help="Deprecated alias for --scripts-coverage (kept for older docs / muscle memory)",
    )
    args = p.parse_args(argv)

    decomp = args.decomp.resolve()
    workspace = args.workspace.resolve()
    if not (decomp / "data" / "maps").is_dir():
        print(f"error: decomp maps missing under {decomp}", file=sys.stderr)
        return 1

    print(f"understanding_pipeline starting at {now_iso_lima()}")
    print(f"  decomp:     {decomp}")
    print(f"  workspace:  {workspace}")
    if args.scripts_coverage or args.scripts_corridor:
        import parse_scripts as ps  # noqa: E402

        if args.scripts_corridor and not args.scripts_coverage:
            print(
                "note: --scripts-corridor is a deprecated alias; prefer --scripts-coverage",
                file=sys.stderr,
            )
        rc = ps.main(
            ["--script-coverage", "--decomp", str(decomp), "--workspace", str(workspace)]
        )
        if rc != 0:
            print(
                "warning: parse_scripts --script-coverage reported failures",
                file=sys.stderr,
            )
    status = run_cycle(
        decomp,
        workspace,
        skip_parse=args.skip_parse,
        skip_serialize=args.skip_serialize,
    )
    print(
        f"done: total={status['total_maps']} "
        f"parse_ok={status['parse_ok']} parse_fail={status['parse_fail']} "
        f"serialize_ok={status['serialize_ok']} serialize_fail={status['serialize_fail']} "
        f"open_issues={len(status['open_issues'])}"
    )
    print(f"wrote {workspace / 'parsed' / 'understanding_status.json'}")
    for issue in status["open_issues"]:
        print(f"  issue[{issue['id']}] owner={issue['owner']} maps={len(issue['maps'])}: {issue['summary'][:120]}")
    return 0 if status["parse_fail"] == 0 and status["serialize_fail"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
