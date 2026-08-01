/// Design tokens for FirstRole — the *non-color* layer: spacing, radius,
/// elevation, and typography (size/weight/letter-spacing only). Translated
/// 1:1 from the design system's `tokens/*.css`.
///
/// Phase 10 (frontend rebuild v2): this file is the surviving half of the old
/// `app_tokens.dart`. The static light-only `AppColors` that used to live
/// alongside these was deleted once every screen migrated to the theme-aware
/// `context.c` (`app_colors.dart`). Color is now owned entirely by the theme:
/// [AppTypography] deliberately carries **no** color — primary text inherits
/// the themed ink via the `ThemeData.textTheme`, and muted text is coloured at
/// the call site with `context.c.inkSoft` / `context.c.inkFaint`.
///
/// FlutterFlow analogy: this is FlutterFlow's Theme Settings for sizing and
/// font styles — except written by hand as `static const` fields.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------
// SPACING — 4px grid, mirrors spacing.css
// ---------------------------------------------------------------------
class AppSpacing {
  AppSpacing._();

  static const space0 = 0.0;
  static const space05 = 2.0; // hairline nudges
  static const space1 = 4.0; // icon↔label, chip inner
  static const space2 = 8.0; // tight stack
  static const space3 = 12.0; // card inner padding (compact)
  static const space4 = 16.0; // default gutter / card padding
  static const space5 = 20.0;
  static const space6 = 24.0; // section gap
  static const space8 = 32.0; // screen block gap
  static const space10 = 40.0;
  static const space12 = 48.0;
  static const space16 = 64.0; // empty-state vertical breathing room

  // Layout constants (portrait mobile)
  static const screenPadX = 16.0; // left/right safe gutter
  // AppShell's bottom nav is a floating pill and owns its own height —
  // see kNavPillHeight in widgets/app_shell.dart.
  static const bottomNavH = 56.0; // legacy token, kept for compatibility
  static const touchMin = 44.0; // minimum hit target
  static const headerH = 52.0; // top app-bar height
}

// ---------------------------------------------------------------------
// RADIUS — mirrors radius.css
// ---------------------------------------------------------------------
class AppRadius {
  AppRadius._();

  static const xs = 4.0; // nested tags, tiny badges
  static const sm = 8.0; // inputs, small buttons
  static const md = 12.0; // buttons, inner tiles
  static const lg = 16.0; // cards, sheets
  static const xl = 20.0; // modal / bottom-sheet top
  static const xxl = 28.0; // hero panels
  static const pill = 999.0; // chips, StatusPill, avatars

  static BorderRadius get xsRadius => BorderRadius.circular(xs);
  static BorderRadius get smRadius => BorderRadius.circular(sm);
  static BorderRadius get mdRadius => BorderRadius.circular(md);
  static BorderRadius get lgRadius => BorderRadius.circular(lg);
  static BorderRadius get xlRadius => BorderRadius.circular(xl);
  static BorderRadius get xxlRadius => BorderRadius.circular(xxl);
  static BorderRadius get pillRadius => BorderRadius.circular(pill);
}

// ---------------------------------------------------------------------
// ELEVATION — restrained mobile shadow system, mirrors elevation.css
// ---------------------------------------------------------------------
class AppElevation {
  AppElevation._();

  static const e0 = <BoxShadow>[]; // flush, rely on border

  static const e1 = <BoxShadow>[
    BoxShadow(color: Color(0x0F181822), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x0D181822), offset: Offset(0, 1), blurRadius: 3),
  ];

  static const e2 = <BoxShadow>[
    BoxShadow(color: Color(0x0F181822), offset: Offset(0, 2), blurRadius: 4),
    BoxShadow(color: Color(0x14181822), offset: Offset(0, 4), blurRadius: 10),
  ];

  static const e3 = <BoxShadow>[
    BoxShadow(color: Color(0x1A181822), offset: Offset(0, 4), blurRadius: 12),
    BoxShadow(color: Color(0x1A181822), offset: Offset(0, 8), blurRadius: 24),
  ];

  static const e4 = <BoxShadow>[
    BoxShadow(color: Color(0x1F181822), offset: Offset(0, 8), blurRadius: 20),
    BoxShadow(color: Color(0x29181822), offset: Offset(0, 20), blurRadius: 48),
  ];

  // Pair with a 2px outline-offset equivalent (see FocusRing usage).
  static const focusShadow = <BoxShadow>[
    BoxShadow(color: Color(0x525647E0), spreadRadius: 3),
  ];
}

// ---------------------------------------------------------------------
// TYPOGRAPHY — roles: display / heading / title / body / caption /
// label / mono-data. Base = 15px. Never render UI text below 12px.
// Mirrors typography.css + fonts.css.
//
// Phase 10: these styles carry **no color**. Primary text inherits the
// themed ink through `ThemeData.textTheme`; where a role reads as muted
// (caption/label were secondary; a "tertiary" caption is fainter still),
// colour it at the call site with `context.c.inkSoft` / `context.c.inkFaint`
// so it flips correctly in dark mode.
//
// Dart note: these are getters (not `static const`) because
// GoogleFonts.plusJakartaSans() is a function call, not a compile-time
// constant.
// ---------------------------------------------------------------------
class AppTypography {
  AppTypography._();

  static TextStyle get display => GoogleFonts.plusJakartaSans(
    fontSize: 32,
    height: 38 / 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02 * 32,
  );

  static TextStyle get heading => GoogleFonts.plusJakartaSans(
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.01 * 22,
  );

  static TextStyle get headingSm => GoogleFonts.plusJakartaSans(
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w600,
  );

  static TextStyle get title => GoogleFonts.plusJakartaSans(
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w600,
  );

  static TextStyle get body => GoogleFonts.plusJakartaSans(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w400,
  );

  static TextStyle get bodyStrong => body.copyWith(fontWeight: FontWeight.w600);

  static TextStyle get bodySm => GoogleFonts.plusJakartaSans(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  // Reads as muted/secondary by design — colour with `context.c.inkSoft` at
  // the call site where the surrounding ink would otherwise be too strong.
  static TextStyle get caption => GoogleFonts.plusJakartaSans(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
  );

  // Pair with `.toUpperCase()` at the call site — CSS text-transform has
  // no Dart TextStyle equivalent, it has to be applied to the string.
  // Reads as muted/secondary by design (see caption).
  static TextStyle get label => GoogleFonts.plusJakartaSans(
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.04 * 11,
  );

  static TextStyle get monoData => GoogleFonts.jetBrainsMono(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.01 * 14,
  );
}
