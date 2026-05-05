# Retro Rewind Movie Workshop v1.8.2

Fixes the New Release texture-sharing bug and adds a sort option for genre tabs.

## The bug in v1.8.1

When you added more than one New Release in the same genre, the tool gave them duplicate texture-slot numbers under the hood. The result, depending on what you did next:

- **Multiple NRs ended up sharing the same cover image.** You'd add three Horror NRs and they'd all show the same standee artwork in-game.
- **Custom covers you assigned didn't show up.** If you mapped a cover image to a New Release and added more NRs in the same genre afterwards, the later ones overwrote the earlier ones at build time. Only one of the conflicting covers actually appeared in-game.
- **Romance, Western, Comedy, Kids, Police, Xmas: every NR shared one cover.** These genres have only one (or zero) base game slots, so all the NRs you added there pointed to the same texture.
- **Adult and Adventure don't support custom NRs.** That's a game-side limitation, not the tool.

The known Discord workaround was to hand-edit `nr_custom_slots.json` and assign each NR a unique `tex_num` value — but only specific numbers worked, and the practical ceiling was around 20 NRs total across all genres (the sum of the base game's NR slots: 3 Action, 1 Comedy, 3 Drama, 2 Fantasy, 4 Horror, 1 Kids, 1 Police, 4 Sci-Fi, 1 Xmas). Going beyond that gave you missing textures, broken standees, and usually required a fresh save to recover.

## What v1.8.2 changes

**Each New Release gets its own slot, automatically.** When you click "Add NR" the tool picks an unused slot number for that genre and produces a texture file for it during build. No JSON editing, no shared covers, no slot conflicts.

**Cover image assignments stick.** Assigning a custom cover to one NR no longer overwrites another NR's cover — each NR has its own underlying texture file now, so each assignment is preserved.

**Sort dropdown for genre tabs and the New Releases tab.** Sort by name, by when you added the entry, or by when you last edited it. Each tab remembers its own sort. The "All Movies" overview keeps its natural order on purpose.

A note for v1.8.1 saves: movies created before this update don't have "created at" or "last edited at" timestamps stored — those fields are new. "Last edited at" gets filled in the next time you edit such a movie. "Created at" can't be backfilled retroactively, so the date sorts treat un-timestamped entries as a separate group: they show up after the timestamped ones, in slot order (for genre tabs) or grouped by genre then slot number (for New Releases). Movies you create in v1.8.2 onward sort correctly by their actual dates. Sort by name works for everyone.

**Older save files migrate automatically.** If your `nr_custom_slots.json` is from v1.8.1, the tool reads it on launch and renumbers any duplicate texture slots so each NR ends up with a unique cover. Titles, SKUs, and cover image assignments are preserved.

If you previously assigned cover images that didn't appear in-game (because of the overwrite bug), they should appear correctly after upgrading.

**Smaller fixes**

- "Remove all custom movies" now also resets the per-movie status badges. Before, new movies you added in the freed slots could appear as "Shipped" or "Edited", inheriting state from the deleted ones.
- The "Edited" badge updates right away after changing rating, rarity, or rotating an image — not only after the next image upload on some other slot.

## How far I've tested

I tested with 50 New Releases per genre — around 550 total across the eleven NR-capable genres — and everything built and loaded without issues. Higher numbers should be fine, but I haven't verified them. If you push into the thousands and something breaks, please open an issue or let me know on Discord.

## Upgrading from v1.8.1

Your tool data is forward-compatible. No data loss.

1. Download `RR_Movie_Workshop_v1.8.2.zip` and extract it into a **new** folder.
2. From your old tool folder, copy these files into the new folder:
   - `nr_custom_slots.json` (your New Releases)
   - `custom_slots.json` (your custom genre-shelf movies)
   - `replacements.json` (your cover image mappings)
   - `config.json` (your paths to the game and texconv/repak)
3. Launch `RR_Movie_Workshop.exe`. On first run you may see one or both of:
   - `[NR] Renumbered '...': tex_num X → Y` — duplicate slots get unique numbers.
   - `[NR] Migrated N bkg_tex entries to 3-digit format` — older entries upgraded to the new naming.
4. Click **Build** to rebuild the mod pak. It's copied to your `~mods\` folder automatically.
5. Launch the game. New Releases that previously shared a cover, or had no cover at all, now show their own.

If your existing save game shows odd behavior after upgrading, starting a new save resolves any leftover mismatch.

## Download

Download `RR_Movie_Workshop_v1.8.2.zip`, extract anywhere, and run `RR_Movie_Workshop.exe`. Everything is included — no Python or extra software.

### Included

- `RR_Movie_Workshop.exe`
- `tools/repak.exe` (MIT License)
- `tools/texconv.exe` (MIT License)
- License files for the bundled tools

### Checksums

See `checksums.txt` for SHA256 hashes to verify file integrity.

### Nexus Mods

Also available at: https://www.nexusmods.com/retrorewindvideostoresimulator/mods/82
