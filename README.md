# Retro Rewind Movie Workshop

Custom VHS cover art and New Release standee tool for [Retro Rewind](https://store.steampowered.com/app/2427940/Retro_Rewind/) (Steam).

## What it does

A standalone GUI tool that lets you replace VHS cover art and create custom New Release standees across all 12 genres. No modding knowledge required — upload images, customize details, click "Ship to Store" and the tool generates a ready-to-play `.pak` mod file.

- Up to 999 movies per genre (~13,000 total)
- Custom New Release standees for 11 genres
- Visual editor with layout preview matching in-game rendering
- One-click build — outputs a single `.pak` file directly to your game's `~mods` folder

## Requirements

- Windows PC
- Python 3.10+ with Pillow (`pip install pillow`)
- [repak.exe](https://github.com/trumank/repak/releases/latest) — pak file operations
- [texconv.exe](https://github.com/microsoft/DirectXTex/releases/latest) — texture conversion
- Retro Rewind (Steam version)

## Running from source

```
pip install pillow
python RR_VHS_Tool.py
```

Place `repak.exe` and `texconv.exe` in the same folder or in a `tools/` subfolder. The tool auto-detects them on first launch.

## Building the executable

```
pip install pyinstaller pillow
build.bat
```

Output goes to `dist/RR_Movie_Workshop/`.

## Download

Pre-built releases with all tools included are available on [Nexus Mods](https://www.nexusmods.com/retrorewindvideostoresimulator/mods/82).

## License

MIT License — see [LICENSE](LICENSE)

## Credits

- Tool by MagicMastaBlasta
- Thanks to Omniscye / Empress for the Real Movies Mod reference
- repak by Truman Kilen & spuds (MIT License)
- texconv by Microsoft / DirectXTex (MIT License)
