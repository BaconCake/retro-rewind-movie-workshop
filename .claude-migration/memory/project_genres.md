---
name: Genre relevance — Adventure is unused
description: Adventure genre exists in base game files but is not used in-game; no priority in the Flutter port either
type: project
originSessionId: 79a3470f-0ae9-4f2e-9657-01b4201bebb4
---
The 13 genres ported from Python's GENRES dict include "Adventure" with a 3-slot DataTable, but the Adventure genre is NOT actually used in the Retro Rewind game. It may or may not be enabled in a future game update.

**Why:** It exists in the base-game .pak (we extract its DataTable, parser handles it correctly) but the in-game UI never surfaces Adventure movies. Test fixtures for Adventure exposed an unusual structural quirk — its base-game uexp ends *exactly* at the row block with a zero-byte tail (no PLAIN_FOOTER, no TMap hash). The other 12 genres have a non-empty trailer.

**How to apply:** Don't waste effort on Adventure-specific edge cases. The parser/builder must not *crash* on Adventure (it's still part of the base pak and gets extracted), but Adventure-only failures or quirks can be deprioritised. If the Flutter UI needs to hide a genre, hide Adventure. Don't write bug-fixes to make Adventure's missing-trailer case feel "normal" — accept the zero-tail as legitimate and move on.

**Important separate fact:** `genres.dart` `bkgCount` is the *texture* count (T_Bkg_Xxx_NN textures available in the base pak), NOT the actual visible-slot count in the base-game DataTable. Action ships with `bkgCount: 15` but its DataTable only has ~2 visible slots — the other 13 textures exist for future slots. Python's port hardcodes per-genre slot lists in `CLEAN_DT_SLOT_DATA` to fill up the visible count; our Dart port currently reads visible slots from the base DataTable instead. If you see "Action only has 2 movies in-game", that's the base-game state, not a bug.
