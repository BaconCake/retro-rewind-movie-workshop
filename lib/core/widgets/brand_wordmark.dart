/// "RETRO REWIND VHS" brand wordmark (LN-4) — the one place in the app
/// where VT323 (CRT-style display font) + multi-layer text bloom is
/// allowed.  Rendered top-left in the app shell, once per screen.
///
/// Font note: VT323 loads via [GoogleFonts].  If the network is
/// unreachable on first launch, GoogleFonts silently falls back to the
/// system serif.  The wordmark stays legible — it just loses the CRT
/// character until the font caches.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../theme/bloom.dart';

class BrandWordmark extends StatelessWidget {
  /// Wordmark font size; defaults to 28 for the app shell.  Pass a
  /// smaller value for in-page usage (about boxes, splash dialogs).
  final double size;
  const BrandWordmark({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.vt323(
      fontSize: size,
      height: 1.0,
      letterSpacing: size * 0.02,
    );
    return RichText(
      text: TextSpan(
        style: base,
        children: [
          TextSpan(
            text: 'retro rewind',
            style: base.copyWith(
              color: kColorPink,
              shadows: textBloom(kColorPink),
            ),
          ),
          TextSpan(
            text: ' vhs',
            style: base.copyWith(
              color: kColorCyan,
              shadows: textBloom(kColorCyan),
            ),
          ),
        ],
      ),
    );
  }
}
