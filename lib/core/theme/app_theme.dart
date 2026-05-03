/// Visual design system for the Flutter port.
///
/// Colours, spacing and typography ported from RR_VHS_Tool.py:5805-5947 — the
/// "Performance Edition" design system.  Philosophy: flat, sharp, terminal-
/// inspired.  No shadows, no blur, no gradients, no rounded corners.
///
/// Token rule: every colour or size used in widget code references a constant
/// here.  Never use raw hex strings or magic numbers in widget files.
library;

import 'package:flutter/material.dart';

// ── Backgrounds ───────────────────────────────────────────────────────
const Color kColorBg = Color(0xFF050505); // app window background
const Color kColorPanel = Color(0xFF0B0F14); // panels, sidebars, cards
const Color kColorSurface = Color(0xFF101722); // inputs, inner surfaces
const Color kColorDivider = Color(0xFF1C1C1C); // section separators
const Color kColorBorder = Color(0xFF333333); // default 1px borders

// ── Accents (one colour = one role — never cross-use) ────────────────
const Color kColorCyan = Color(0xFF00F5FF); // active · selected · CTA · OK
const Color kColorPink = Color(0xFFFF0055); // edit · custom · error · upload
const Color kColorGold = Color(0xFFFFD84A); // rarity · highlights · stars
const Color kColorDisabled = Color(0xFF5A5A5A); // disabled controls

// ── Text ──────────────────────────────────────────────────────────────
const Color kColorText = Color(0xFFF2F5F7); // primary
const Color kColorText2 = Color(0xFFA8B0B8); // secondary
const Color kColorText3 = Color(0xFF6A7A7A); // muted (logs, placeholders)
const Color kColorTextInv = Color(0xFF050505); // text on cyan buttons

// ── Spacing (4 px grid) ───────────────────────────────────────────────
const double kSp1 = 4;
const double kSp2 = 8;
const double kSp3 = 12;
const double kSp4 = 16;
const double kSp6 = 24;

// ── Font sizes (1080p baseline; Material's textTheme picks them up) ──
const double kFsApp = 15;
const double kFsSec = 14;
const double kFsBody = 13;
const double kFsMeta = 11;

/// Monospace font stack.  Flutter resolves through the list at runtime, so
/// Windows users get Consolas, others fall back to whatever the OS provides
/// (usually Menlo/Courier New).  Matches RR_VHS_Tool.py:5959.
const String kFontFamily = 'Consolas';
const List<String> kFontFamilyFallback = ['Cascadia Code', 'Courier New'];

/// The full ThemeData for the app.  Always dark — the design system has no
/// light variant and the Python tool is dark-only too.
ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    surface: kColorPanel,
    surfaceContainerLowest: kColorBg,
    surfaceContainerLow: kColorPanel,
    surfaceContainer: kColorPanel,
    surfaceContainerHigh: kColorPanel,
    surfaceContainerHighest: kColorSurface,
    onSurface: kColorText,
    onSurfaceVariant: kColorText2,
    outline: kColorBorder,
    outlineVariant: kColorDivider,
    primary: kColorCyan,
    onPrimary: kColorTextInv,
    secondary: kColorPink,
    onSecondary: kColorTextInv,
    tertiary: kColorGold,
    onTertiary: kColorTextInv,
    error: kColorPink,
    onError: kColorTextInv,
    errorContainer: Color(0xFF400015),
    onErrorContainer: kColorPink,
  );

  final textTheme = const TextTheme(
    headlineSmall:
        TextStyle(fontSize: kFsApp, fontWeight: FontWeight.w700, color: kColorText),
    titleSmall:
        TextStyle(fontSize: kFsSec, fontWeight: FontWeight.w700, color: kColorText),
    bodyMedium: TextStyle(fontSize: kFsBody, color: kColorText),
    bodySmall: TextStyle(fontSize: kFsMeta, color: kColorText2),
    labelSmall: TextStyle(fontSize: kFsMeta, color: kColorText3),
  ).apply(
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFamilyFallback,
    bodyColor: kColorText,
    displayColor: kColorText,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kColorBg,
    canvasColor: kColorBg,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFamilyFallback,
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: kColorPanel,
      foregroundColor: kColorText,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFamilyFallback,
        fontSize: kFsApp,
        fontWeight: FontWeight.w700,
        color: kColorPink, // matches Python's "RETRO REWIND" pink wordmark
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: kColorBorder,
      thickness: 1,
      space: 1,
    ),
    cardTheme: const CardThemeData(
      color: kColorPanel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: kColorBorder),
        borderRadius: BorderRadius.zero,
      ),
    ),
    iconTheme: const IconThemeData(color: kColorText2),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: kColorText2,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      selectedColor: kColorCyan,
      selectedTileColor: kColorSurface,
      iconColor: kColorText2,
      textColor: kColorText,
      // Selected ListTile gets a cyan left stripe via leading widget, but
      // Material's ListTile doesn't expose a stripe slot natively, so the
      // sidebar widget paints it explicitly.
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kColorCyan,
        foregroundColor: kColorTextInv,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        padding: const EdgeInsets.symmetric(horizontal: kSp4, vertical: kSp3),
        textStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontFamilyFallback: kFontFamilyFallback,
          fontWeight: FontWeight.w700,
          fontSize: kFsBody,
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kColorSurface,
      contentTextStyle: TextStyle(
        color: kColorText,
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFamilyFallback,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kColorCyan,
      linearTrackColor: kColorBorder,
      circularTrackColor: kColorBorder,
    ),
  );
}
