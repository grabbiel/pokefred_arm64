#!/usr/bin/env python3
"""Parse script/flag/var symbols from Map Parser JSON and attach summaries.

Additive only: writes parsed/<MapName>.scripts.json (does NOT mutate map JSON).
Stdlib only. Decomp is read-only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_DECOMP = Path("/Users/rumpology/code/repo/32bit/pokefirered")
DEFAULT_WORKSPACE = Path("/Users/rumpology/code/repo/32bit/pokefred_arm64")

NULLISH = frozenset({"0", "0x0", "NULL", "", "None"})

# Heuristic one-liners when label matches common patterns (Pallet → Pewter corridor+)
HEURISTIC_SUMMARY = [
    (re.compile(r"OakTrigger", re.I), "Oak intro stop: prevents leaving town without a Pokémon; leads player to the lab."),
    (re.compile(r"SignLady", re.I), "Sign-lady NPC / trigger: teaches Start-menu / Trainer Tips interaction."),
    (re.compile(r"FatMan", re.I), "Town NPC dialogue (PC storage tip)."),
    (re.compile(r"LabSign|OaksLabSign|PlayersHouseSign|RivalsHouseSign|TownSign|CitySign|RouteSign|GymSign|ExitSign|DiglettsCaveSign|TrainerTips|NicknameSign", re.I), "Sign / bg text readout."),
    (re.compile(r"BulbasaurBall|SquirtleBall|CharmanderBall", re.I), "Starter Poké Ball: confirm choice, give mon, rival takes the counter-type."),
    (re.compile(r"LeaveStarterScene", re.I), "Blocks leaving the lab until a starter is chosen."),
    (re.compile(r"RivalBattleTrigger|RivalBattle", re.I), "Post-starter rival battle trigger (position-aware approach)."),
    (re.compile(r"ProfOak\b", re.I), "Prof. Oak interact: starter/dex/balls/national-dex scene dispatcher."),
    (re.compile(r"Aide\d", re.I), "Lab aide NPC dialogue (Fame Checker after game clear)."),
    (re.compile(r"Pokedex\b", re.I), "Desk Pokédex prop dialogue."),
    (re.compile(r"Computer\b", re.I), "Lab computer email sign text."),
    (re.compile(r"LeftSign|RightSign", re.I), "Lab wall sign text (menu/type tips)."),
    # Pallet houses
    (re.compile(r"PlayersHouse_1F_EventScript_Mom|EventScript_Mom\b", re.I), "Mom interact: Oak looking-for-you / heal party at home."),
    (re.compile(r"EventScript_TV|EventScript_TVScreen|EventScript_NES|EventScript_PC\b", re.I), "Home prop interact (TV / NES / PC)."),
    (re.compile(r"EventScript_Daisy|GiveTownMap|TownMap\b|GroomMon|RateMonFriendship", re.I), "Daisy / rival's sister: Town Map gift or friendship groom/rate."),
    (re.compile(r"Bookshelf|Picture\b", re.I), "Indoor prop text (bookshelf / picture)."),
    # Route1 / Viridian / Pewter corridor
    (re.compile(r"MartClerk|AlreadyGotPotion", re.I), "Route gift NPC: free Potion (once) from Viridian Mart clerk on Route 1."),
    (re.compile(r"TutorialTrigger|DoTutorialBattle|TutorialOldMan|TutorialStart", re.I), "Viridian old-man catch tutorial battle / Teachy TV scene."),
    (re.compile(r"RoadBlocked|GymDoor|TryUnlockGym|GymDoorLocked", re.I), "Viridian road/gym lock until story flags (parcel / badges)."),
    (re.compile(r"DreamEaterTutor", re.I), "Move tutor NPC (Dream Eater)."),
    (re.compile(r"ParcelScene|SayHiToOak", re.I), "Oak's Parcel pickup scene at Viridian Mart."),
    (re.compile(r"GymGuideTrigger|GymGuide\b|WalkToGym", re.I), "Pewter gym guide: escorts first-time visitors to Brock's gym."),
    (re.compile(r"EntranceTrigger|TryPayForTicket|OldAmber|AerodactylFossil|KabutopsFossil", re.I), "Pewter Museum ticket gate / fossil / Old Amber scenes."),
    (re.compile(r"EventScript_Nurse", re.I), "Pokémon Center nurse heal."),
    (re.compile(r"EventScript_Clerk|Items::", re.I), "Poké Mart clerk / item list."),
    (re.compile(r"Colosseum|TradeCenter|RecordCorner", re.I), "Pokémon Center 2F link-room attendant."),
    (re.compile(r"EventScript_Brock|DefeatedBrock|GiveTM39", re.I), "Gym Leader Brock battle / TM39 reward."),
    (re.compile(r"EventScript_Giovanni|DefeatedGiovanni|GiveTM26", re.I), "Gym Leader Giovanni battle / TM26 reward."),
    (re.compile(r"GymGuy|GymStatue", re.I), "Gym tip guy or victory statue text."),
    (re.compile(r"EventScript_Aide\b|AlreadyGotHM05|GetAideRequestInfo", re.I), "Oak aide HM/item gift (Route 2 gate; dex-count gated)."),
    (re.compile(r"EventScript_Reyley|DeclineTrade|AlreadyTraded|NotRequestedMon", re.I), "In-game trade NPC."),
    (re.compile(r"Jigglypuff", re.I), "Ambient Jigglypuff NPC (song / flavor)."),
    # Shared field-move / center scripts (data/scripts/)
    (re.compile(r"EventScript_CutTree|EventScript_FldEffCut|EventScript_CantCutTree", re.I), "Cut field move: chop a cuttable tree (badge/HM gated)."),
    (re.compile(r"EventScript_RockSmash|EventScript_FldEffRockSmash|EventScript_CantSmashRock", re.I), "Rock Smash field move (badge/HM gated)."),
    (re.compile(r"EventScript_StrengthBoulder|EventScript_FldEffStrength|EventScript_CantMoveBoulder|EventScript_AlreadyUsedStrength", re.I), "Strength field move: push boulder (badge/HM gated)."),
    (re.compile(r"EventScript_Waterfall|EventScript_CantUseWaterfall", re.I), "Waterfall field move (badge/HM gated)."),
    (re.compile(r"EventScript_DeepWater|EventScript_CantDive|EventScript_TrySurface|EventScript_CantSurface", re.I), "Dive / underwater surface field move."),
    (re.compile(r"EventScript_PkmnCenterNurse", re.I), "Pokémon Center nurse heal (shared)."),
    (re.compile(r"EventScript_PC\b", re.I), "PC access script (shared)."),
    (re.compile(r"EventScript_HiddenItem|HiddenItemScript", re.I), "Hidden item pickup (shared)."),
    # Cerulean / Mt. Moon / Nugget Bridge / Bill corridor
    (re.compile(r"EventScript_Misty|DefeatedMisty|GiveTM03|TM03", re.I), "Gym Leader Misty battle / TM reward."),
    (re.compile(r"BikeShop|Bicycle\b|BikeVoucher", re.I), "Cerulean Bike Shop: bicycle / voucher exchange."),
    (re.compile(r"CeruleanCaveGuard", re.I), "Cerulean Cave entrance guard (story-gated)."),
    (re.compile(r"DomeFossil|HelixFossil", re.I), "Mt. Moon fossil choice (Dome vs Helix)."),
    (re.compile(r"Grunt|Rocket\b", re.I), "Team Rocket grunt battle / scene."),
    (re.compile(r"Nugget|RocketTrigger", re.I), "Nugget Bridge / Rocket reward scene (Route 24)."),
    (re.compile(r"EventScript_Bill\b|SeaCottage", re.I), "Bill's Sea Cottage: Pokémon Storage System / rescue scene."),
    (re.compile(r"MegaKickTutor|MegaPunchTutor|MoveTutor", re.I), "Move tutor NPC."),
    (re.compile(r"WonderNews|BerryCrush|BerryPowder", re.I), "Berry / Wonder News / Powder house interact."),
    (re.compile(r"BadgeGuy|WallHole", re.I), "Cerulean house flavor NPC / prop."),
    (re.compile(r"Slowbro", re.I), "Cerulean Slowbro NPC (flavor / follows trainer)."),
    (re.compile(r"Policeman|CeruleanCity_EventScript_Grunt", re.I), "Cerulean stolen-TM / Rocket chase aftermath."),
    (re.compile(r"UndergroundPathSign", re.I), "Underground Path entrance sign."),
    (re.compile(r"MtMoonSign|ZubatSign", re.I), "Mt. Moon area sign / flavor text."),
    (re.compile(r"ItemTM|ItemEscapeRope|ItemMoonStone|ItemRareCandy|ItemPotion|ItemAntidote|ItemRevive|ItemStarPiece|ItemParalyzeHeal", re.I), "Visible item ball pickup."),
    # Generic trainers (after specific leaders)
    (re.compile(r"EventScript_(Rick|Doug|Sammy|Anthony|Charlie|Liam|Jason|Cole|Atsushi|Kiyo|Takashi|Samuel|Yuji|Warren)\b", re.I), "Trainer battle script (see body for trainerbattle_*)."),
    (re.compile(r"Rival\b", re.I), "Rival interact dialogue (waits for / reacts to starter choice)."),
]

# Body-command hints used when no label heuristic matches
BODY_CMD_HINTS = [
    (re.compile(r"\btrainerbattle_", re.I), "Trainer battle script."),
    (re.compile(r"\bgiveitem", re.I), "Gives an item (once / gated)."),
    (re.compile(r"\bpokemart\b", re.I), "Opens Poké Mart inventory."),
    (re.compile(r"\bcall\s+EventScript_OutOfCenterPartyHeal|\bspecial\s+HealPlayerParty|\bcallstd\s+STD_MESSAGE_HEAL", re.I), "Heals the player's party."),
    (re.compile(r"\bsetflag\b", re.I), "Sets a story/item flag."),
    (re.compile(r"\bmsgbox\b.*MSGBOX_SIGN", re.I), "Sign / bg text readout."),
    (re.compile(r"\bmsgbox\b.*MSGBOX_NPC", re.I), "NPC dialogue."),
    (re.compile(r"\blockall\b", re.I), "Coord/cutscene trigger (lockall)."),
]


def collect_symbols(doc: dict) -> dict[str, dict]:
    """Return symbol -> {kind, refs:[{field, index, ...}]}."""
    out: dict[str, dict] = {}

    def add(sym: str, kind: str, ref: dict) -> None:
        if not sym or sym in NULLISH:
            return
        entry = out.setdefault(sym, {"symbol": sym, "kind": kind, "refs": []})
        # Prefer more specific kind if we previously guessed wrong
        if entry["kind"] == "unknown" and kind != "unknown":
            entry["kind"] = kind
        entry["refs"].append(ref)

    for i, ev in enumerate(doc.get("object_events") or []):
        if ev.get("type") == "clone":
            continue
        if "script" in ev:
            add(str(ev["script"]), "script", {"field": "object_events", "index": i, "xy": [ev.get("x"), ev.get("y")]})
        if "flag" in ev:
            add(str(ev["flag"]), "flag", {"field": "object_events", "index": i, "role": "hide_flag"})
    for i, ev in enumerate(doc.get("coord_events") or []):
        if "script" in ev:
            add(str(ev["script"]), "script", {"field": "coord_events", "index": i, "xy": [ev.get("x"), ev.get("y")]})
        if "var" in ev:
            add(str(ev["var"]), "var", {"field": "coord_events", "index": i, "var_value": ev.get("var_value")})
    for i, ev in enumerate(doc.get("bg_events") or []):
        if "script" in ev:
            add(str(ev["script"]), "script", {"field": "bg_events", "index": i, "xy": [ev.get("x"), ev.get("y")]})
        if "flag" in ev:
            add(str(ev["flag"]), "flag", {"field": "bg_events", "index": i, "role": "hidden_item_flag"})
        if "item" in ev:
            add(str(ev["item"]), "item", {"field": "bg_events", "index": i})
    # warps have no scripts in pret FR
    return out


def find_label_in_inc(inc_path: Path, label: str) -> tuple[int, list[str]] | None:
    """Return (1-based line, body lines until next label) or None."""
    if not inc_path.is_file():
        return None
    text = inc_path.read_text(encoding="utf-8", errors="replace")
    # Labels appear as Name:: or Name:
    pat = re.compile(rf"^{re.escape(label)}::?\s*$", re.M)
    m = pat.search(text)
    if not m:
        return None
    start = m.end()
    line_no = text.count("\n", 0, m.start()) + 1
    rest = text[start:]
    # Next top-level label (same indent, word::)
    nxt = re.search(r"^[A-Za-z_][A-Za-z0-9_]*::?\s*$", rest, re.M)
    body = rest[: nxt.start()] if nxt else rest
    lines = [ln.rstrip() for ln in body.splitlines() if ln.strip() and not ln.strip().startswith("@")]
    return line_no, lines[:40]



def find_shared_script_label(decomp: Path, label: str) -> tuple[str, list[str]] | None:
    """Search data/scripts/*.inc for a shared label.

    Returns (definition_path_with_line, body_lines) or None.
    Prefers an exact ``data/scripts/<label>.inc`` filename hit, then scans all
    ``*.inc`` files under ``data/scripts/`` (e.g. EventScript_CutTree in field_moves.inc).
    """
    scripts_dir = decomp / "data" / "scripts"
    if not scripts_dir.is_dir():
        return None
    exact = scripts_dir / f"{label}.inc"
    candidates: list[Path] = []
    if exact.is_file():
        candidates.append(exact)
    candidates.extend(
        sorted(p for p in scripts_dir.glob("*.inc") if p.resolve() != exact.resolve())
    )
    seen: set[Path] = set()
    for inc in candidates:
        key = inc.resolve()
        if key in seen:
            continue
        seen.add(key)
        hit = find_label_in_inc(inc, label)
        if hit:
            line_no, body = hit
            return f"data/scripts/{inc.name}:{line_no}", body
    return None


def resolve_symbol(decomp: Path, map_name: str, sym: str, kind: str) -> dict:
    info: dict = {"symbol": sym, "kind": kind, "definition": None, "summary": None}
    if kind == "item" or sym.startswith("ITEM_"):
        info["kind"] = "item"
        path = decomp / "include" / "constants" / "items.h"
        if path.is_file():
            for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if re.search(rf"#define\s+{re.escape(sym)}\b", line):
                    info["definition"] = f"include/constants/items.h:{i}"
                    info["summary"] = "Hidden/given item constant; see items.h."
                    return info
        info["summary"] = "Item constant; see items.h."
        return info
    if kind == "flag" or sym.startswith("FLAG_"):
        info["kind"] = "flag"
        path = decomp / "include" / "constants" / "flags.h"
        if path.is_file():
            for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if re.search(rf"#define\s+{re.escape(sym)}\b", line):
                    info["definition"] = f"include/constants/flags.h:{i}"
                    info["summary"] = line.strip()
                    return info
        info["summary"] = "Flag constant (hide/show or system); see flags.h."
        return info
    if kind == "var" or sym.startswith("VAR_"):
        info["kind"] = "var"
        path = decomp / "include" / "constants" / "vars.h"
        if path.is_file():
            for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if re.search(rf"#define\s+{re.escape(sym)}\b", line):
                    info["definition"] = f"include/constants/vars.h:{i}"
                    # TEMP vars cleared on map load
                    if "TEMP" in sym:
                        info["summary"] = "Temporary map var (cleared on map load); used for trigger branch state."
                    else:
                        info["summary"] = "Persistent scene/progress var; gates coord triggers and dialogue branches."
                    return info
        info["summary"] = "Var constant; see vars.h."
        return info

    # script: map-local first, then shared data/scripts/*.inc
    info["kind"] = "script"
    map_inc = decomp / "data" / "maps" / map_name / "scripts.inc"
    hit = find_label_in_inc(map_inc, sym)
    if hit:
        line_no, body = hit
        info["definition"] = f"data/maps/{map_name}/scripts.inc:{line_no}"
        info["summary"] = summarize_script(sym, body)
        info["body_preview"] = body[:12]
        return info
    shared = find_shared_script_label(decomp, sym)
    if shared:
        rel_def, body = shared
        info["definition"] = rel_def
        info["summary"] = summarize_script(sym, body)
        info["body_preview"] = body[:12]
        return info
    # Cheap fallback: a few Common_* attendants live inline in event_scripts.s
    es = decomp / "data" / "event_scripts.s"
    hit = find_label_in_inc(es, sym)
    if hit:
        line_no, body = hit
        info["definition"] = f"data/event_scripts.s:{line_no}"
        info["summary"] = summarize_script(sym, body)
        info["body_preview"] = body[:12]
        return info
    info["summary"] = (
        "Script label not found in map scripts.inc, data/scripts/*.inc, "
        "or data/event_scripts.s (may live in another map)."
    )
    return info


def summarize_script(sym: str, body: list[str]) -> str:
    for pat, tip in HEURISTIC_SUMMARY:
        if pat.search(sym):
            return tip
    blob = "\n".join(body)
    for pat, tip in BODY_CMD_HINTS:
        if pat.search(blob):
            return tip
    cmds = []
    for ln in body:
        tok = ln.strip().split()[0] if ln.strip() else ""
        if tok and not tok.startswith("."):
            cmds.append(tok)
    head = ", ".join(cmds[:8]) if cmds else "(empty)"
    return f"Event script; leading commands: {head}."


def parse_map_scripts(decomp: Path, workspace: Path, map_query: str) -> dict:
    parsed_path = workspace / "parsed" / f"{map_query}.json"
    if not parsed_path.is_file():
        # allow full path
        p = Path(map_query)
        if p.is_file():
            parsed_path = p
        else:
            raise FileNotFoundError(f"parsed JSON not found: {parsed_path}")
    doc = json.loads(parsed_path.read_text(encoding="utf-8"))
    map_name = doc["name"]
    symbols = collect_symbols(doc)
    resolved = []
    for sym, meta in sorted(symbols.items()):
        r = resolve_symbol(decomp, map_name, sym, meta["kind"])
        r["maps"] = [map_name]
        r["refs"] = meta["refs"]
        resolved.append(r)
    return {
        "map_id": doc.get("map_id"),
        "name": map_name,
        "source_parsed": str(parsed_path),
        "symbol_count": len(resolved),
        "scripts": {r["symbol"]: r for r in resolved if r["kind"] == "script"},
        "flags": {r["symbol"]: r for r in resolved if r["kind"] == "flag"},
        "vars": {r["symbol"]: r for r in resolved if r["kind"] == "var"},
        "other": {r["symbol"]: r for r in resolved if r["kind"] not in ("script", "flag", "var")},
    }


# Pallet → Viridian → Pewter corridor (+ Pallet indoor neighbors) — slice 1 / PR #5
CORRIDOR_MAPS = [
    "PalletTown",
    "PalletTown_PlayersHouse_1F",
    "PalletTown_PlayersHouse_2F",
    "PalletTown_RivalsHouse",
    "PalletTown_ProfessorOaksLab",
    "Route1",
    "Route21_North",
    "Route21_South",
    "ViridianCity",
    "ViridianCity_PokemonCenter_1F",
    "ViridianCity_PokemonCenter_2F",
    "ViridianCity_Mart",
    "ViridianCity_House",
    "ViridianCity_School",
    "ViridianCity_Gym",
    "Route2",
    "Route2_ViridianForest_SouthEntrance",
    "Route2_ViridianForest_NorthEntrance",
    "Route2_EastBuilding",
    "Route2_House",
    "ViridianForest",
    "PewterCity",
    "PewterCity_Gym",
    "PewterCity_Museum_1F",
    "PewterCity_Museum_2F",
    "PewterCity_Mart",
    "PewterCity_PokemonCenter_1F",
    "PewterCity_PokemonCenter_2F",
    "PewterCity_House1",
    "PewterCity_House2",
]

# Slice 2: Pewter → Mt. Moon → Cerulean → Nugget Bridge / Bill → Route5/6 Saffron approach
CERULEAN_CLUSTER_MAPS = [
    "Route3",
    "Route4",
    "Route4_PokemonCenter_1F",
    "Route4_PokemonCenter_2F",
    "MtMoon_1F",
    "MtMoon_B1F",
    "MtMoon_B2F",
    "CeruleanCity",
    "CeruleanCity_BikeShop",
    "CeruleanCity_Gym",
    "CeruleanCity_House1",
    "CeruleanCity_House2",
    "CeruleanCity_House3",
    "CeruleanCity_House4",
    "CeruleanCity_House5",
    "CeruleanCity_Mart",
    "CeruleanCity_PokemonCenter_1F",
    "CeruleanCity_PokemonCenter_2F",
    "Route24",
    "Route25",
    "Route25_SeaCottage",
    "Route5",
    "Route5_PokemonDayCare",
    "Route5_SouthEntrance",
    "Route6",
    "Route6_NorthEntrance",
    "Route6_UnusedHouse",
    "UndergroundPath_NorthEntrance",
    "UndergroundPath_NorthSouthTunnel",
    "UndergroundPath_SouthEntrance",
]

# Union of known additive script-coverage presets (corridor ∪ Cerulean cluster)
SCRIPT_COVERAGE_MAPS = list(dict.fromkeys([*CORRIDOR_MAPS, *CERULEAN_CLUSTER_MAPS]))


def list_script_maps(workspace: Path) -> list[str]:
    """Map names that already have additive *.scripts.json (sorted)."""
    parsed = workspace / "parsed"
    if not parsed.is_dir():
        return []
    return sorted(
        p.name[: -len(".scripts.json")]
        for p in parsed.glob("*.scripts.json")
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Attach script/flag/var summaries (additive *.scripts.json).")
    p.add_argument("maps", nargs="*", help="Map names (parsed/<Name>.json must exist)")
    p.add_argument("--corridor", action="store_true", help="Parse Pallet→Viridian→Pewter corridor set (slice 1)")
    p.add_argument(
        "--cerulean",
        action="store_true",
        help="Parse Pewter→Mt.Moon→Cerulean→Route5/6 cluster (slice 2)",
    )
    p.add_argument(
        "--script-coverage",
        action="store_true",
        help="Parse all known script-coverage presets (corridor ∪ Cerulean cluster)",
    )
    p.add_argument("--all-parsed", action="store_true", help="Parse every map with parsed/<Name>.json")
    p.add_argument("--decomp", type=Path, default=DEFAULT_DECOMP)
    p.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE)
    args = p.parse_args(argv)
    decomp = args.decomp.resolve()
    workspace = args.workspace.resolve()

    maps: list[str] = list(args.maps)
    if args.script_coverage:
        maps.extend(SCRIPT_COVERAGE_MAPS)
    else:
        if args.corridor:
            maps.extend(CORRIDOR_MAPS)
        if args.cerulean:
            maps.extend(CERULEAN_CLUSTER_MAPS)
    if args.all_parsed:
        maps.extend(
            sorted(
                p.stem
                for p in (workspace / "parsed").glob("*.json")
                if not p.name.endswith(".scripts.json")
                and p.name != "understanding_status.json"
                and p.name != "serialize_dry_run_summary.json"
            )
        )
    # de-dupe preserving order
    seen: set[str] = set()
    ordered: list[str] = []
    for m in maps:
        if m not in seen:
            seen.add(m)
            ordered.append(m)
    if not ordered:
        p.error("provide map names and/or --corridor / --cerulean / --script-coverage / --all-parsed")

    fails = 0
    for m in ordered:
        try:
            result = parse_map_scripts(decomp, workspace, m)
        except Exception as e:  # noqa: BLE001
            print(f"error: {m}: {e}", file=sys.stderr)
            fails += 1
            continue
        out = workspace / "parsed" / f"{result['name']}.scripts.json"
        out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(
            f"Wrote {out.name}  scripts={len(result['scripts'])} "
            f"flags={len(result['flags'])} vars={len(result['vars'])}"
        )
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
