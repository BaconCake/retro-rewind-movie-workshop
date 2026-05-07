"""Extract the binary template constants from RR_VHS_Tool.py to disk.

The Python tool embeds 7 binary blobs as base64+zlib-compressed strings:

  - _MI_UASSET_TEMPLATE_B64Z     (1772 bytes decompressed)
  - _MI_UEXP_TEMPLATE_B64Z       (33471 bytes decompressed)
  - _THUMB_TEX_UASSET_TEMPLATE_B64Z
  - _THUMB_TEX_UEXP_HEADER_B64Z
  - _STANDEE_FULLRES_A_B64Z      (JPEG)
  - _STANDEE_FULLRES_B_B64Z      (JPEG)
  - _STANDEE_FULLRES_C_B64Z      (JPEG)

The Flutter port keeps them as standalone files under
assets/standee_templates/ and loads them via rootBundle. This avoids
embedding ~500KB of base64 strings into the Dart sources.

Usage:
  python scripts/extract_standee_templates.py [--source PATH]

Default source path is C:/Users/Sascha/Documents/MODDING/Tools/RR_VHS_Tool.py.

Re-run only when a Python upstream update touches one of these constants.
The output files are checked into git.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import os
import sys
import zlib
from pathlib import Path

DEFAULT_SOURCE = r"C:\Users\Sascha\Documents\MODDING\Tools\RR_VHS_Tool.py"

OUTPUT_FILES = {
    "_MI_UASSET_TEMPLATE_B64Z":     "mi_uasset.bin",
    "_MI_UEXP_TEMPLATE_B64Z":       "mi_uexp.bin",
    "_THUMB_TEX_UASSET_TEMPLATE_B64Z": "thumb_uasset.bin",
    "_THUMB_TEX_UEXP_HEADER_B64Z":  "thumb_uexp_header.bin",
    "_STANDEE_FULLRES_A_B64Z":      "standee_a.jpg",
    "_STANDEE_FULLRES_B_B64Z":      "standee_b.jpg",
    "_STANDEE_FULLRES_C_B64Z":      "standee_c.jpg",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=DEFAULT_SOURCE,
                        help="Path to RR_VHS_Tool.py")
    parser.add_argument("--out", default=None,
                        help="Output directory "
                             "(default: <repo>/assets/standee_templates)")
    args = parser.parse_args()

    source_path = Path(args.source)
    if not source_path.exists():
        print(f"ERROR: source not found: {source_path}", file=sys.stderr)
        return 1

    if args.out:
        out_dir = Path(args.out)
    else:
        # Resolve repo root from this script's location.
        out_dir = Path(__file__).resolve().parent.parent / "assets" / "standee_templates"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Load the Python file as a module so the constants get evaluated by the
    # interpreter — we rely on the b64z assignments being plain string literals
    # at module scope, which they are in RR_VHS_Tool.py.
    #
    # Importing the full module would also run heavy I/O at import time, so we
    # instead grab the constants by parsing the file as text and evaluating
    # each assignment independently.
    text = source_path.read_text(encoding="utf-8")

    # Build a small namespace seeded with `b64decode` and `decompress` so the
    # tool's `zlib.decompress(base64.b64decode(...))` lines work directly.
    ns = {"base64": base64, "zlib": zlib}

    written = 0
    for const_name, out_name in OUTPUT_FILES.items():
        # Find the assignment line: e.g. `_MI_UASSET_TEMPLATE_B64Z = (`.
        marker = f"\n{const_name} = "
        idx = text.find(marker)
        if idx < 0:
            print(f"ERROR: constant {const_name} not found in source",
                  file=sys.stderr)
            return 2

        # Walk forward, tracking parenthesis depth, until we close the
        # tuple that holds the multi-line string parts.
        start = idx + len(marker)
        # The b64z strings are wrapped in `(... )` with concatenated lines.
        # We need to find the matching close-paren.
        depth = 0
        end = start
        in_string = False
        string_char = ""
        for i, ch in enumerate(text[start:], start=start):
            if in_string:
                if ch == "\\":
                    continue  # naive: skip the next char
                if ch == string_char:
                    in_string = False
                continue
            if ch in ("'", '"'):
                in_string = True
                string_char = ch
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
            elif ch == "\n" and depth == 0:
                end = i
                break

        expr = text[start:end].strip()
        try:
            value = eval(expr, ns)  # noqa: S307 - controlled input
        except Exception as exc:
            print(f"ERROR: failed to eval {const_name}: {exc}", file=sys.stderr)
            return 3

        if not isinstance(value, str):
            print(f"ERROR: {const_name} did not eval to str", file=sys.stderr)
            return 4

        try:
            decoded = zlib.decompress(base64.b64decode(value))
        except Exception as exc:
            print(f"ERROR: decode failed for {const_name}: {exc}",
                  file=sys.stderr)
            return 5

        out_path = out_dir / out_name
        out_path.write_bytes(decoded)
        print(f"  {const_name:<35} -> {out_name:<22} {len(decoded):>7} bytes")
        written += 1

    print(f"\nWrote {written} template files to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
