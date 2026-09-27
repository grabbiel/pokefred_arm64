# AST Parser — map + script understanding

Stdlib Python tools. Decomp (`pokefirered`) is **read-only**. Outputs land under workspace `parsed/` (local; do not commit — Workspace I/O owns ignore).

| Tool | Role |
|------|------|
| `parse_map.py` | pret map.json + map.bin → `parsed/<Map>.json` |
| `parse_scripts.py` | Additive `parsed/<Map>.scripts.json` (script/flag/var symbols + summaries) |
| `serialize_map.py` | Validate / pack / dry-run compare (Serializer allowlists); `--write` is fail-closed + Serializer-owned |
| `understanding_pipeline.py` | Parse all maps + serialize dry-run → `parsed/understanding_status.json` |

## Script coverage slices

| Flag | Maps |
|------|------|
| `--corridor` | Slice 1: Pallet → Viridian → Pewter (30) |
| `--cerulean` | Slice 2: Route3/4 → Mt. Moon → Cerulean → Route24/25 → Route5/6 + N/S Underground Path (30) |
| `--vermilion` | Slice 3: Vermilion (+ indoors/Fan Club) → Diglett's Cave → Routes 9–11 → Rock Tunnel / Power Plant → SS Anne key decks (30) |
| `--lavender` | Slice 4: Lavender (+ indoors/Volunteer House) → Pokémon Tower 1F–7F → Route8/12/13 → E–W Underground Path → Route7 / Celadon approach (30) |
| `--script-coverage` | Union of slices 1–4 (120) |

```bash
# Requires parsed/<Map>.json already (or run full pipeline first)
python3 tools/parse_scripts.py --script-coverage

# Or refresh scripts then re-check serialize dry-run without rewriting map JSON:
python3 tools/understanding_pipeline.py --skip-parse --scripts-coverage
# (--scripts-corridor remains a deprecated alias for --scripts-coverage)
```

`parse_scripts.py` never mutates map JSON schema. Summaries use label heuristics + cheap body-command hints (`trainerbattle_`, `giveitem`, `pokemart`, …).

Shared labels such as `EventScript_CutTree` resolve from `data/scripts/*.inc` (not only map-local `scripts.inc`).

Slim `parse_map` object events preserve `script`/`flag` but omit some pret fields (`movement_range_*`, trainer sight). Safe while writes are map.bin-focused + dry-run; if map.json rewrite ever used slim docs without merging existing pret JSON, those fields would be lost (Serializer handoff).

## Full understanding cycle

```bash
python3 tools/understanding_pipeline.py
# expect: parse_ok == serialize_ok == total_maps (488), open_issues empty when clean
```

**`serialize_ok` scope:** packed `map.bin` byte-identity vs decomp disk after `validate_document` + `pack_map_bin` only. It does **not** mean map.json events/scripts were rewritten or that `slim_compare_events` passed.

`serialize_map.py --write` stays fail-closed (refuses git-dirty targets without `--force`) and is Serializer-owned; this pipeline never passes `--write`.
