import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
// Only the sizing tokens — `show` avoids the deliberate `AppColors` name clash
// between app_tokens.dart (legacy static palette) and app_colors.dart (the new
// ThemeExtension). See app_colors.dart's header note.
import 'app_tokens.dart' show AppSpacing, AppRadius;

/// Phase 2 (frontend rebuild v2) — light/dark [ThemeData] built from the
/// semantic [AppColors] token layer. `MaterialApp(theme: appLight, darkTheme:
/// appDark, themeMode: …)` in main.dart; the mode is owned by `ThemeController`.
///
/// The component theming (buttons, inputs, cards, app bar, bottom nav) is ported
/// from the previous light-only `AppTheme.light` but now reads every colour from
/// the theme-appropriate `AppColors c`, so dark mode is real rather than a
/// re-tinted light theme. Legacy screens that still read `app_tokens.dart`
/// statics stay light-coloured until they migrate (Phase 5+); that's the
/// deliberate opportunistic-migration path, not a bug.

/// Monospace numerals (fit scores, salaries, token counts, dates, costs).
TextStyle mono(double size, {FontWeight w = FontWeight.w500, Color? color}) =>
    GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: w, color: color);

/// Display serif for the big hero fit score only.
TextStyle serifScore(double size, Color color) => GoogleFonts.playfairDisplay(
      fontSize: size,
      fontWeight: FontWeight.w800,
      color: color,
      height: 1,
    );

ThemeData _base(AppColors c, Brightness b) {
  final textTheme = GoogleFonts.interTextTheme()
      .apply(bodyColor: c.ink, displayColor: c.ink);
  final onAccent = b == Brightness.dark ? c.ink : Colors.white;

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: c.paper,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
      primary: c.accent,
      onPrimary: onAccent,
      secondary: c.info,
      surface: c.surface,
      onSurface: c.ink,
      error: c.critical,
    ),
    textTheme: textTheme,
    extensions: [c],
    appBarTheme: AppBarTheme(
      backgroundColor: c.surface,
      foregroundColor: c.ink,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle:
          GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: c.ink),
      toolbarHeight: AppSpacing.headerH,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.lgRadius,
        side: BorderSide(color: c.border),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: onAccent,
        disabledBackgroundColor: c.surface2,
        disabledForegroundColor: c.inkFaint,
        minimumSize: const Size.fromHeight(AppSpacing.touchMin),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdRadius),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        side: BorderSide(color: c.border),
        minimumSize: const Size.fromHeight(AppSpacing.touchMin),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdRadius),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface2,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.space4,
        vertical: AppSpacing.space3,
      ),
      border: OutlineInputBorder(
        borderRadius: AppRadius.smRadius,
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.smRadius,
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.smRadius,
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppRadius.smRadius,
        borderSide: BorderSide(color: c.critical),
      ),
      hintStyle: textTheme.bodyLarge?.copyWith(color: c.inkFaint),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: c.surface,
      selectedItemColor: c.accent,
      unselectedItemColor: c.inkFaint,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    splashFactory: NoSplash.splashFactory,
  );
}

final ThemeData appLight = _base(AppColors.light, Brightness.light);
final ThemeData appDark = _base(AppColors.dark, Brightness.dark);
