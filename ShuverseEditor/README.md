# Shuverse Editor

Native Apple Silicon map editor for the Shuverse Editor Suite. The app is Swift, AppKit, and Metal (`MTKView`). Dear ImGui (docking branch, vendored under `ImGuiHost/`) draws the tool docks on a transparent overlay. The map itself loads Map Parser JSON into `EditorDocument` / `MapDocument` / `MapCell` and draws Pallet Town from GBA 4bpp tiles and RGB555 palettes.

Pallet Town (`Samples/PalletTown.json`) is a 24×20 metatile map (384×320 px).

## Requirements

- Apple Silicon Mac (arm64). The executable is compiled with an `#error` for every other architecture, including Rosetta.
- macOS 13 or later
- Xcode 15 or later, or a Swift 5.9+ toolchain that can build for `arm64-apple-macos`

The map model is pure Swift. `swift test` does not need Metal or ImGui and can run on other hosts. The windowed editor, including the dock host, cannot: `Package.swift` adds the executable and the `CImGuiHost` C++ target only on macOS.

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

SwiftPM compiles the vendored Dear ImGui sources (`ImGuiHost/imgui`, tag `v1.91.9b-docking`) into `CImGuiHost` and links that into the executable. There is no extra ImGui install. The official Metal/OSX backends are Objective-C++ (`.mm`), which SwiftPM does not compile, so event routing and the ImGui draw are Swift (`ImGuiOverlayView`, `ImGuiMetalRenderer`). They use a separate command queue from the map canvas.

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

## Docks

A transparent `MTKView` covers the window and draws four Dear ImGui panels: **Map List**, **Inspector**, **Status**, and **Tileset**. The center dock node is empty and pass-through, so the Metal map stays visible there.

- Map List shows open maps (the sample name is enough when only Pallet Town is loaded) and can open the sample or a JSON file.
- Inspector shows the same cell and event text as before (metatile id, attribute, packed `u16`, object / warp / trigger / sign).
- Status shows zoom, pan, the selected cell, and the renderer note.
- Tileset is a placeholder grid. Palette paint is not in this slice.

Drag a tab or splitter to rearrange docks for the session. The layout is not written to an ini file.

The overlay’s `hitTest` asks ImGui whether the cursor is on a panel, tab, or splitter. On the central hole it returns nil, and the map view keeps the event. Pan, zoom, pinch, and click-inspect do not go through ImGui. Scrolling over a dock scrolls that panel.

## Canvas

GPU notes (shared grid, triple-buffering, depth, tile-shader overlays): [docs/metal_gpu.md](../docs/metal_gpu.md). The dock overlay does not change that pass.

- Drag to pan. A short click inspects the metatile under the cursor.
- Scroll wheel, pinch, or ⌘-scroll to zoom toward the pointer. Menu or `+` / `-` zoom about the center. `0` or `f` fits the map. Arrow keys pan.
- Marker colors: white object, gold warp, cyan trigger, orange sign. The gold outline is the selection.
- Pallet Town ground pixels come from `Samples/tilesets/pallet_town/` (primary + secondary `.4bpp`, 32-byte RGB555 `.pal` banks, pret `metatiles.bin`). Formats match `tools/pixel_pipeline/CONTRACT.md`. Rebuild with `Scripts/bake_pallet_town_tiles.py`. `MetatileColor` is not uploaded.
