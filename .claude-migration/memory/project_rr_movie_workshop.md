---
name: RR Movie Workshop project context
description: Flutter desktop port of the 14k-line RR_VHS_Tool.py (Retro Rewind modding tool); slice plan, layout, source pointers
type: project
originSessionId: 79a3470f-0ae9-4f2e-9657-01b4201bebb4
---
Working dir: `C:\Users\sasch\Documents\MODDING\Retro Rewind\Movie_Workshop\RR Movie Workshop`. Python original lives one level up at `..\RR_VHS_Tool.py`.

Dart package name: `rr_movie_workshop` (folder name has spaces, package must be snake_case). Window title / display name: "RR Movie Workshop".

Architecture: Clean / layered — `lib/{core,domain,data,presentation}/`. Riverpod 2.x for DI/state, hand-written providers (no codegen). Multi-platform desktop scaffold (Windows + macOS + Linux) but user only develops on Windows.

**Why:** A multi-step port from a monolithic Python tool. MIGRATION.md is the contract: each "slice" proves a piece end-to-end before adding the next. Slice 1 = toolchain wiring only (config.json → repak.exe → install passthrough pak); content-modifying logic is deferred.

**How to apply:** When adding features, check MIGRATION.md's deferral table first. Don't pull DataTable/texture-injection/preview logic forward unless we're explicitly on slice 2+. The Python source is the source of truth — port constants verbatim (genres, error codes, repak argv) and keep file/JSON-key compatibility so users can switch tools without losing data.

Slice progress (live-verified by user clicking "Ship to Store" and launching game):
- **Slice 1** (toolchain wiring): done 2026-05-01.
- **Slice 2a** (real AssetRegistry extraction): done 2026-05-01.
- **Slice 2b** (PakCache as unified extraction service): done 2026-05-01.
- **Slice 2c** (full DataTable rebuild — parser, name-table extender, row synthesizer, full builder/manager + PakBuilder integration): **done 2026-05-02**. All 13 genres rebuilt as 1-row-per-slot uasset+uexp pairs, game loads pak, movies render normally. The most complex binary-surgery slice — every offset is now nailed down.

Open scope per MIGRATION.md: slice 3 (texture injection via texconv + DXT1 + uasset clone), slice 4 (preview canvas + slot-editing UI), slice 5 (NewRelease/standees), slice 6 (setup dialog).
