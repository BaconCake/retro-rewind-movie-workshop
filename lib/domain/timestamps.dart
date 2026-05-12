/// Format a [DateTime] (or `DateTime.now()`) as Python's `_now_iso()`
/// would (RR_VHS_Tool.py:2792-2795):
///
///   * Local time (no UTC conversion).
///   * Second precision — microseconds stripped.
///   * No timezone suffix — naive datetime, no trailing `Z`.
///
/// Example: `2026-05-12T08:58:00`.
///
/// Why local-time:  the Python tool writes timestamps in this format
/// into the shared `custom_slots.json` / `nr_custom_slots.json` files.
/// Existing user libraries (e.g. tested 2026-05-12 against a real NR
/// file) already contain entries like `"last_edited_at":
/// "2026-05-10T19:37:25"` — no Z, no millis.  Mixing UTC-with-Z and
/// local-without-Z in the same file breaks lex-sort because Z (0x5A)
/// is greater than digit characters, so a UTC string sorts *after* a
/// local-time string of the same wall-clock moment.  Keeping every
/// write in Python's format avoids that landmine.
///
/// The optional [now] parameter exists for testability — when the
/// caller injects a UTC `DateTime`, this still strips the `Z` so the
/// formatted result matches what production writes.
String nowIso([DateTime? now]) =>
    (now ?? DateTime.now()).toIso8601String().split('.').first;
