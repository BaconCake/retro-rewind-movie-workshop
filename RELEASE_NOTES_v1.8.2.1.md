# Retro Rewind Movie Workshop v1.8.2.1

Single-bugfix patch on top of v1.8.2.

## What this fixes

If you upgraded an existing save from v1.8.1 to v1.8.2 and you had New
Releases already sitting in your store, the shelf showed the base game's
default cover for those NRs — even though their custom covers were
loaded correctly in the tool, and the standees showed the right
artwork. v1.8.2.1 fixes that.

## Why this happened

v1.8.2 renamed New Release texture slots internally from 2-digit
(`T_New_Sci_01`) to 3-digit (`T_New_Sci_001`) so each NR could get its
own unique slot. The standees got rebuilt at the same time and pointed
correctly at the new slots — that's why standees worked. But your save
game still references the **old** 2-digit slot names for any NRs that
were already in your store before the upgrade. Those old slots no
longer carried your custom cover after v1.8.2, so the shelf fell back
to the base game default.

## What v1.8.2.1 changes

When building the mod, the tool now also writes your custom cover to
the legacy 2-digit slot — but only for NRs whose slot number falls
within the base game's NR count for that genre (3 Action, 1 Comedy,
3 Drama, 2 Fantasy, 4 Horror, 1 Kids, 1 Police, 4 Sci-Fi, 1 Xmas).
NRs beyond those counts (e.g. your fifth Sci-Fi NR) only existed in
3-digit slots anyway, so old saves can't reference them and nothing
needs to change there.

## Edge case worth knowing

If in v1.8.1 you had **more** NRs in a single genre than the base game
provides slots for (e.g. 5 Sci-Fi NRs when base only has 4), all of
those NRs ended up sharing texture slot 1 due to the v1.8.1 bug. After
the v1.8.2 migration each NR has a unique number, but only one of them
ends up at the legacy slot 1. After upgrading to v1.8.2.1, your old
save will show **that one NR's cover** for all the in-store NRs that
inherited from slot 1, instead of the default. It's an improvement,
but starting a fresh save is still the only way to get each individual
NR showing its own correct cover for that specific case.

For everyone else (NR counts within the base slot range per genre),
this patch fully restores correct covers in your existing save.

## Upgrading

1. Download `RR_Movie_Workshop_v1.8.2.1.zip` and extract it into a new
   folder (or the same one you used for v1.8.2 — overwrite is fine).
2. Copy your JSONs across if you used a new folder:
   `nr_custom_slots.json`, `custom_slots.json`, `replacements.json`,
   `config.json`.
3. Launch the tool. On first run you'll see `Cache stamp v1.8.2 != v1.8.2.1
   — wiping to rebuild` — that's expected.
4. Click **Build**. Look for `[NR-Legacy] Co-injected T_New_*_NN` lines
   in the console for each NR that gets the legacy cover.
5. Launch the game. NRs that were missing covers in v1.8.2 should now
   show the right artwork.

No data migration this time — your `nr_custom_slots.json` from v1.8.2
is used as-is.

## Download

Download `RR_Movie_Workshop_v1.8.2.1.zip`, extract anywhere, and run
`RR_Movie_Workshop.exe`. Everything is included — no Python or extra
software.

### Included

- `RR_Movie_Workshop.exe`
- `tools/repak.exe` (MIT License)
- `tools/texconv.exe` (MIT License)
- License files for the bundled tools

### Checksums

See `checksums.txt` for SHA256 hashes to verify file integrity.

### Nexus Mods

Also available at: https://www.nexusmods.com/retrorewindvideostoresimulator/mods/82
