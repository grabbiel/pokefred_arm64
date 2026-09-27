# pokefred_arm64

ARM64 port of Pokémon FireRed, and the native Shuverse Editor Suite.

## Shuverse Editor

Apple Silicon macOS map editor (Swift, AppKit, Metal). It loads Map Parser JSON into the multi-map in-memory model and draws a fake-colored metatile grid. Pallet Town in the sample is 24×20.

There is no GBA C rewrite and no Electron/Rosetta build. The editor refuses to compile for any architecture other than `arm64`.

- Model notes: [docs/map_model.md](docs/map_model.md)
- Package and run instructions: [ShuverseEditor/README.md](ShuverseEditor/README.md)
- Sample map: [ShuverseEditor/Samples/PalletTown.json](ShuverseEditor/Samples/PalletTown.json)

On Apple Silicon, from this repo:

```bash
cd ShuverseEditor
swift test
swift build --arch arm64
swift run --arch arm64 ShuverseEditor
```

Xcode’s Swift accepts `--arch arm64`. If the toolchain only offers `--triple`, use `swift build --triple arm64-apple-macosx13.0`. On an Apple Silicon Mac, a plain `swift build` is already arm64.

`swift test` checks the model (Pallet Town decodes to 480 cells). `swift run` opens that sample in the Metal view. Pass another parser JSON path as the argument, or use File → Open Map JSON….
