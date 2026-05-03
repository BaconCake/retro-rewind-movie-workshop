# RR VHS Tool — Flutter Desktop Port

A Flutter desktop port of `RR_VHS_Tool.py` (Retro Rewind Movie Workshop).

## What this is

This is **slice 1** of a multi-step port from the 14k-line Python tool to a
clean, layered Flutter desktop app. The goal of slice 1 is **not** feature
parity — it is to prove the toolchain wiring works end-to-end:

> Flutter app → reads `config.json` → invokes `repak.exe` → produces a
> valid `zzzzzz_MovieWorkshop_P.pak` → installs it to `~mods` → game accepts it.

Everything else (DataTable rebuilding, texture injection, preview canvas,
New Releases, etc.) is deferred to later slices.

The pak built by slice 1 is a **passthrough** — the game will load it
without crashing, but it doesn't yet change anything in-game. That's
intentional. We add the modding logic on top of a known-working pipeline.

## Architecture

Clean architecture, three layers:

```
lib/
├── core/                       # constants, error codes, pure utilities
│   ├── constants/genres.dart   # GENRES, GENRE_DATATABLE, texture dims
│   └── utils/build_error.dart  # E001..E015 codes (matching Python)
│
├── domain/                     # pure Dart, no Flutter/IO
│   ├── entities/               # AppConfig, Texture, BuildResult
│   └── repositories/           # abstract interfaces
│
├── data/                       # IO + JSON + subprocess
│   ├── datasources/            # JsonFileDataSource
│   ├── dtos/                   # ConfigDto (matches Python config.json)
│   └── repositories/           # concrete impls (incl. PakBuilderImpl)
│
└── presentation/               # Flutter UI + Riverpod
    ├── providers/              # Riverpod DI + BuildController
    ├── pages/home_page.dart
    └── widgets/                # GenreSidebar, TextureGrid, BuildPanel
```

State management is **Riverpod** (`flutter_riverpod` 2.x, hand-written
providers — no codegen yet so the project builds with `flutter pub get`
alone).

## Prerequisites

You need a working Python tool setup already, since slice 1 reuses the
same external binaries and config file:

- **Flutter** 3.22+ with desktop support enabled for your platform
  (`flutter config --enable-windows-desktop` on Windows).
- **`repak.exe`** — same binary the Python tool uses.
- **`texconv.exe`** — same binary the Python tool uses (not actually
  invoked in slice 1, but the config check verifies the path).
- **`RetroRewind-Windows.pak`** — base game pak.
- **`~mods` folder** — the game's mods folder.

## Configuration

The Flutter app reads the **same `config.json` format** as the Python tool.
If you have a working `config.json` from the Python version, copy it next
to the Flutter executable (or run `flutter run` from a directory containing
it).

Schema:

```json
{
  "texconv": "C:/path/to/texconv.exe",
  "repak":   "C:/path/to/repak.exe",
  "base_game_pak": "D:/SteamLibrary/.../RetroRewind-Windows.pak",
  "mods_folder":   "D:/SteamLibrary/.../~mods"
}
```

> **Note.** Slice 1 does not yet include a setup dialog. If `config.json`
> is missing, the app launches but the Build button reports missing tools.
> Drop a working `config.json` next to the executable (or in the project
> root if you're running with `flutter run`) and restart.

## Running

```bash
cd rr_vhs_tool
flutter pub get
flutter run -d windows   # or -d macos / -d linux
```

### Smoke test for the build pipeline

1. Place a valid `config.json` in the project root.
2. Click **Ship to Store** in the right panel.
3. Watch the build log. Expected output:

   ```
   [Build] Starting build (Flutter port v0.1.0-flutter)
   [Build] Work dir: ...
   [Build] Extracting AssetRegistry.bin from base pak...
   [Build] (slice 1) AssetRegistry extraction skipped — empty pak
   [Build] Running: repak pack --version V11
   [Build] Pak built: 0.00 MB
   [Build] Installed to: .../~mods/zzzzzz_MovieWorkshop_P.pak
   ```

4. Launch the game. It should load normally (the mod pak doesn't change
   anything yet, so you should see no visible difference). If the game
   refuses to start or crashes on load, the toolchain wiring has a
   regression vs Python — that's slice 1's failure mode.

## Tests

```bash
flutter test
```

Slice 1 ships with two tests:

- `config_dto_test.dart` — verifies the `config.json` schema parses
  identically to what the Python tool writes.
- `texture_repository_test.dart` — verifies texture enumeration matches
  the Python `build_texture_list()` fallback path (slot counts per genre,
  3-digit zero-padding, `T_Bkg_<code>_NNN` naming).

## What's deliberately missing (deferred to later slices)

| Feature                            | Where in Python              | Slice |
| ---------------------------------- | ---------------------------- | ----- |
| `CleanDataTableBuilder` (binary)   | lines 2840-3662              | 2     |
| `DataTableManager`                 | lines 4737-5095              | 2     |
| `PakCache` (real unpack/cache)     | lines 5096-5541              | 2     |
| `inject_texture` (texconv calls)   | lines 5576-5894              | 3     |
| DXT1 decoding for thumbnails       | lines 2623-2688              | 3     |
| Preview canvas (zoom/pan/snap)     | VHSToolApp                   | 4     |
| Slot editing (titles, SKU, stars)  | VHSToolApp                   | 4     |
| New Release / standees             | lines 3663-4472              | 5     |
| Setup dialog                       | `SetupDialog`                | 6     |

## Design notes

- **Subprocess parity.** `Process.run` in Dart matches `subprocess.run` in
  Python, including `exitCode`, `stdout`, `stderr`. Every external command
  (`repak unpack`, `repak pack`, `texconv -f DXT1 ...`) ports 1:1.
- **JSON file compatibility.** All persisted state uses the same filenames
  and field names as Python (`config.json`, `replacements.json`,
  `nr_custom_slots.json`, etc.) so a user can switch between tools without
  losing data.
- **Working directory.** Mirrors the Python tool: the directory containing
  the executable. During development with `flutter run`, that's the build
  output directory, which is fine for slice 1.
- **No code generation in slice 1.** Riverpod providers are written by
  hand. We can switch to `riverpod_generator` later if it pays off.

## Known issues / open questions for slice 2

- Real `AssetRegistry.bin` extraction needs to be wired up (the Python
  `_extract_asset_registry`). Easy port but requires the actual base pak
  to test against.
- The DataTable binary patching code (`CleanDataTableBuilder`) is the
  most-commented part of the Python source for good reason — every offset
  is a hard-won fact. Plan to port it with the comments intact and keep
  parity tests against Python-produced binaries.
