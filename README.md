# RR Movie Workshop

Retro Rewind Movie Workshop — Flutter desktop port of the original
`RR_VHS_Tool.py` modding tool.

> The original Python tool is preserved on the **`legacy-python`** branch
> of this repository.

## Status

Sliced rollout per [`MIGRATION.md`](MIGRATION.md). Slice progress:

| Slice | Scope                                                              | Status |
| ----- | ------------------------------------------------------------------ | ------ |
| 1     | Toolchain wiring (config → repak → install passthrough pak)        | Done   |
| 2a    | Real `AssetRegistry.bin` extraction                                | Done   |
| 2b    | `PakCache` as unified extraction service                           | Done   |
| 2c    | Full DataTable rebuild (parser + builder + manager + integration)  | Done   |
| 3     | Texture injection (texconv + DXT1 + uasset clone)                  | Open   |
| 4     | Preview canvas + slot-editing UI                                   | Open   |
| 5     | NewRelease / standees                                              | Open   |
| 6     | Setup dialog                                                       | Open   |

See `MIGRATION.md` for architecture, deferral table, and design notes.

## Prerequisites

- **Flutter** 3.22+ with desktop support enabled
  (`flutter config --enable-windows-desktop` on Windows).
- **`repak.exe`** and **`texconv.exe`** binaries (same ones the Python
  tool used).
- **`RetroRewind-Windows.pak`** — the base game pak.
- The game's **`~mods`** folder.

## Configuration

Drop a `config.json` next to the executable (or in the project root for
`flutter run`). Schema:

```json
{
  "texconv": "C:/path/to/texconv.exe",
  "repak":   "C:/path/to/repak.exe",
  "base_game_pak": "C:/.../RetroRewind-Windows.pak",
  "mods_folder":   "C:/.../~mods"
}
```

`config.json` is **gitignored** — paths are per-machine.

## Run

```powershell
flutter pub get
flutter run -d windows
```

## Test

```powershell
flutter test
```

## Layout

```
lib/
├── core/          # constants (genres, error codes), pure utilities
├── domain/        # entities + abstract repositories (no Flutter / IO)
├── data/          # IO, JSON DTOs, subprocess, repository impls
└── presentation/  # Riverpod providers, pages, widgets
```
