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
// LN-1: Late-Night-Rental tonal-elevation extensions to the Background
// stack.  Use these for cards on panels / hover targets (elevated) and
// for the strongest selected-surface tier (selected).
const Color kColorElevated = Color(0xFF18222F);
const Color kColorSelected = Color(0xFF243149);

// ── Accents (one colour = one role — never cross-use) ────────────────
const Color kColorCyan = Color(0xFF00F5FF); // active · selected · CTA · OK
const Color kColorPink = Color(0xFFFF0055); // edit · custom · error · upload
const Color kColorGold = Color(0xFFFFD84A); // rarity · highlights · stars
const Color kColorDisabled = Color(0xFF5A5A5A); // disabled controls
// LN-1: dedicated advisory + confirmed-build roles.  Frees gold from
// doing double duty as both rarity *and* "warning, action needed", and
// gives "shipped in the latest build" its own colour that's clearly
// different from cyan's generic OK.
const Color kColorWarn = Color(0xFFF5A623);    // advisory state
const Color kColorShipped = Color(0xFF6EE54A); // in the latest build

// ── Build-status badges (Python RR_VHS_Tool.py:11447-11458) ──────────
// Three-state model: UNSHIPPED (never built) > EDITED (built, then
// changed) > none (built and clean).  Same hex values as Python so the
// two tools' shelves render side-by-side identically.
const Color kColorBadgeUnshipped = Color(0xFF8B3333); // dark red
const Color kColorBadgeEdited = Color(0xFFF5A623); // amber

// ── Text ──────────────────────────────────────────────────────────────
const Color kColorText = Color(0xFFF2F5F7); // primary
const Color kColorText2 = Color(0xFFA8B0B8); // secondary
const Color kColorText3 = Color(0xFF6A7A7A); // muted (logs, placeholders)
// LN-1: faintest tier — separators, code chrome, hairline labels.
// Below kColorText3 in luminance so it visually recedes further than
// "muted" but is still legible at body size on the panel background.
const Color kColorText4 = Color(0xFF4A5570);
const Color kColorTextInv = Color(0xFF050505); // text on cyan buttons

// ── Genre palette (LN-1) ──────────────────────────────────────────────
// One colour per genre — matched-luminance picks intended for tabs,
// sidebar dots, list-row stripes and card edge stripes.  Use the
// [kGenreAccent] map below instead of switch statements scattered
// across the codebase.
//
// Naming note: the briefing referenced this map as `kGenreColors`, but
// that symbol is taken by an older [GenreColor] bg/fg pair-map in
// `core/constants/genres.dart` that drives the legacy filled-tab look.
// We use `kGenreAccent` here and migrate call sites to it incrementally
// (LN-5 tab strip, LN-6 movie card); the legacy map gets removed once
// no caller references it.
const Color kGenreAction    = Color(0xFF4DD4FF);
const Color kGenreAdult     = Color(0xFFE84A6B);
const Color kGenreComedy    = Color(0xFFFFD84A);
const Color kGenreDrama     = Color(0xFF9D7BFF);
const Color kGenreFantasy   = Color(0xFFD660FF);
const Color kGenreHorror    = Color(0xFFFF3333);
const Color kGenreKids      = Color(0xFF5BC8FA);
const Color kGenrePolice    = Color(0xFF5A84D4);
const Color kGenreRomance   = Color(0xFFFF6B9D);
const Color kGenreSciFi     = Color(0xFF00E5D0);
const Color kGenreWestern   = Color(0xFFD9A45A);
const Color kGenreChristmas = Color(0xFF4ADE80);

/// Genre-name → accent colour lookup.  Keys match the Python-style
/// genre names used by `kGenres` in `core/constants/genres.dart` so a
/// caller can do `kGenreAccent[g.name]` directly.  Returns null for
/// "All Movies" and "New Releases" (those use [kColorCyan] as the
/// brand fall-through).
const Map<String, Color> kGenreAccent = {
  'Action':  kGenreAction,
  'Adult':   kGenreAdult,
  'Comedy':  kGenreComedy,
  'Drama':   kGenreDrama,
  'Fantasy': kGenreFantasy,
  'Horror':  kGenreHorror,
  'Kids':    kGenreKids,
  'Police':  kGenrePolice,
  'Romance': kGenreRomance,
  'Sci-Fi':  kGenreSciFi,
  'Western': kGenreWestern,
  'Xmas':    kGenreChristmas,
};

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

// ── Motion (LN-1) ─────────────────────────────────────────────────────
// Three-tier duration scale.  `kAnimFast` for state cuts that need
// to feel instant but not jarring (hover bloom, focus ring).  `kAnimBase`
// for the default state transition between idle and active.
// `kAnimBreathe` is the slow "this is still happening" loop length —
// used by BreathingDot to pulse pending/error states.
const Duration kAnimFast = Duration(milliseconds: 120);
const Duration kAnimBase = Duration(milliseconds: 200);
const Duration kAnimBreathe = Duration(milliseconds: 2000);
const Curve kCurveStandard = Cubic(0.2, 0.7, 0.2, 1.0);

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
    // LN-1: shipped-lime gets the tertiaryContainer slot — semantically
    // "confirmed / in the latest build" sits adjacent to tertiary
    // (highlights) and gives Material's themed surfaces something to
    // hand out when a widget asks for `colorScheme.tertiaryContainer`.
    tertiaryContainer: kColorShipped,
    onTertiaryContainer: kColorTextInv,
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
