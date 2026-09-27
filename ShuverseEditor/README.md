# Shuverse Editor

Native Apple Silicon map editor for the Shuverse Editor Suite. The app is Swift, AppKit, and Metal (`MTKView`). It loads Map Parser JSON into `EditorDocument` / `MapDocument` / `MapCell` and draws each metatile in a stable fake color. Real tileset pixels are intentionally not in this version.

Pallet Town (`Samples/PalletTown.json`) is a 24×20 metatile map (384×320 px).

## Requirements

- Apple Silicon Mac (arm64). The executable is compiled with an `#error` for every other architecture, including Rosetta.
- macOS 13 or later
- Xcode 15 or later, or a Swift 5.9+ toolchain that can build for `arm64-apple-macos`

The map model is pure Swift. `swift test` does not need Metal and can run on other hosts. The windowed editor cannot.

## Build and run

From this directory, on Apple Silicon:

```bash
swift test
swift build --arch arm64
swift run --arch arm64 ShuverseEditor
```

Xcode’s Swift accepts `--arch arm64`. A Swift.org toolchain that only has `--triple` can use:

```bash
swift build --triple arm64-apple-macosx13.0
```

`swift build` with no flag is also arm64 when the Mac itself is Apple Silicon. The executable `#error`s for any other architecture.

From the repo root:

```bash
swift test --package-path ShuverseEditor
swift run --package-path ShuverseEditor --arch arm64 ShuverseEditor
```

Xcode: open `Package.swift`, select the **ShuverseEditor** scheme, set the destination to **My Mac**, and run. Do not pick a Rosetta destination.

The built binary is under `.build/arm64-apple-macosx/debug/ShuverseEditor` (or `.build/debug/` when the host is already arm64).

## Load a map

On launch the app opens a map in this order:

1. A path passed on the command line
2. `Samples/PalletTown.json`, walking up from the current directory and from the executable
3. The JSON copied into the app target at `App/Resources/PalletTown.json`

```bash
swift run --arch arm64 ShuverseEditor Samples/PalletTown.json
```

File → Open Map JSON…, File → Open Pallet Town Sample, or drop a `.json` file on the window. Opening another map adds it to the workspace and focuses it. Tileset symbols are deduped in `EditorDocument.sharedTilesets`.

`MapDocument` Codable matches the parser file: `dimensions.width_metatiles`, `blockdata.metatile_ids`, and `blockdata.map_attributes` (bits 0–9 id, bits 10–15 attribute). `EditorDocument` Codable is the workspace (`decompRoot`, `maps`, `activeMapId`, `sharedTilesets`, `dirtyMaps`).

## Canvas

- Drag to pan. A short click inspects the metatile under the cursor.
- Scroll wheel, pinch, or ⌘-scroll to zoom toward the pointer. Menu or `+` / `-` zoom about the center. `0` or `f` fits the map. Arrow keys pan.
- The inspector shows metatile id, map attribute, packed `u16`, and any object, warp, trigger, or sign on that cell.
- Marker colors: white object, gold warp, cyan trigger, orange sign. The gold outline is the selection.

Fake colors are a function of metatile id only. They stay put across runs so the town layout is readable before tileset parse exists.
