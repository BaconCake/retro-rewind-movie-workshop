# Retro Rewind Movie Workshop v1.8.2.2

Small patch with two bugfixes on top of v1.8.2.1.

## What's fixed

- **Blank shelf VHS for legacy NRs beyond base count.** If you played
  v1.8.1 with more New Releases per genre than the base game provides
  slots for and your existing save still has those NRs in-store, their
  shelf VHS now shows the right cover instead of the base game default.
  (v1.8.2.1 fixed this only for NRs within the base slot range; this
  patch extends the fix to the rest.)
- **Deleted NRs and texture overrides reappearing on next build.** If
  you removed a New Release or a custom genre slot in the tool, it
  could still show up in the next build and re-persist in
  `shipped_slots.json` / `edited_slots.json`. Deletes now stick.
  Installs that already accumulated stale entries get cleaned up
  automatically the first time you launch v1.8.2.2.

## Upgrading

Drop `RR_Movie_Workshop_v1.8.2.2.zip` over your v1.8.2.1 install (or
extract into a new folder and copy your JSONs across). On first launch
you'll see `Cache stamp v1.8.2.1 != v1.8.2.2 — wiping to rebuild`,
which is expected. Build once, install, done.

No data migration — your `nr_custom_slots.json` is used as-is.

## Download

Download `RR_Movie_Workshop_v1.8.2.2.zip`, extract anywhere, run
`RR_Movie_Workshop.exe`. Everything is included.

### Included

- `RR_Movie_Workshop.exe`
- `tools/repak.exe` (MIT License)
- `tools/texconv.exe` (MIT License)
- License files for the bundled tools

### Checksums

See `checksums.txt` for SHA256 hashes to verify file integrity.

### Nexus Mods

Also available at: https://www.nexusmods.com/retrorewindvideostoresimulator/mods/82
