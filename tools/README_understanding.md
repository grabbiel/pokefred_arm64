# AST Parser — map + script understanding

Stdlib Python tools. Decomp (`pokefirered`) is **read-only**. Outputs land under workspace `parsed/` (local; do not commit — Workspace I/O owns ignore).

| Tool | Role |
|------|------|
| `parse_map.py` | pret map.json + map.bin → `parsed/<Map>.json` |
| `parse_scripts.py` | Additive `parsed/<Map>.scripts.json` (script/flag/var symbols + summaries) |
| `serialize_map.py` | Validate / pack / dry-run compare (Serializer allowlists) |
| `understanding_pipeline.py` | Parse all maps + serialize dry-run → `parsed/understanding_status.json` |

## Script corridor (Pallet → Viridian → Pewter)

```bash
# Requires parsed/<Map>.json already (or run full pipeline first)
python3 tools/parse_scripts.py --corridor

# Or refresh scripts then re-check serialize dry-run without rewriting map JSON:
python3 tools/understanding_pipeline.py --skip-parse --scripts-corridor
```

`parse_scripts.py` never mutates map JSON schema. Summaries use label heuristics + cheap body-command hints (`trainerbattle_`, `giveitem`, `pokemart`, …).

## Full understanding cycle

```bash
python3 tools/understanding_pipeline.py
# expect: parse_ok == serialize_ok == total_maps (488), open_issues empty when clean
```
