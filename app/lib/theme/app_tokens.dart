/// Design tokens for Job-Hunt Agent, translated 1:1 from the design
/// system's `tokens/*.css` (colors, typography, spacing, radius,
/// elevation). Widgets should read from here, never hardcode a hex/px.
///
/// FlutterFlow analogy: this is the equivalent of FlutterFlow's Theme
/// Settings (Primary/Secondary/Accent colors, font styles) — except
/// written by hand as `static const` fields instead of picked in a UI.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------
// COLOR — base ramps (50→900) + semantic aliases, mirrors colors.css
// ---------------------------------------------------------------------
class AppColors {
  AppColors._();

  // ---- Brand / accent (indigo-violet) --------------------------------
  static const brand50 = Color(0xFFEFEEFC);
  static const brand100 = Color(0xFFE1DEFB);
  static const brand200 = Color(0xFFC7C1F8);
  static const brand300 = Color(0xFFA79EF3);
  static const brand400 = Color(0xFF8676EC);
  static const brand500 = Color(0xFF6B58E6);
  static const brand600 = Color(0xFF5647E0); // primary
  static const brand700 = Color(0xFF4536C4); // hover / press
  static const brand800 = Color(0xFF382C9C);
  static const brand900 = Color(0xFF2E2679);

  // ---- Success (green) -----------------------------------------------
  static const success50 = Color(0xFFE7F6EE);
  static const success100 = Color(0xFFCDEDDB);
  static const success200 = Color(0xFFA0DDBB);
  static const success300 = Color(0xFF6BC894);
  static const success400 = Color(0xFF3EAE72);
  static const success500 = Color(0xFF1F9459);
  static const success600 = Color(0xFF157A49);
  static const success700 = Color(0xFF10633C);
  static const success800 = Color(0xFF0D4E30);
  static const success900 = Color(0xFF0A3D26);

  // ---- Warning (amber) -------------------------------------------------
  static const warning50 = Color(0xFFFEF4E6);
  static const warning100 = Color(0xFFFCE6C2);
  static const warning200 = Color(0xFFF8CE86);
  static const warning300 = Color(0xFFF2B24C);
  static const warning400 = Color(0xFFE9971F);
  static const warning500 = Color(0xFFD07E0A);
  static const warning600 = Color(0xFFA9640A);
  static const warning700 = Color(0xFF85500C);
  static const warning800 = Color(0xFF6A400C);
  static const warning900 = Color(0xFF55340B);

  // ---- Critical (red) --------------------------------------------------
  static const critical50 = Color(0xFFFDECEC);
  static const critical100 = Color(0xFFFAD5D5);
  static const critical200 = Color(0xFFF4AEAE);
  static const critical300 = Color(0xFFEC8080);
  static const critical400 = Color(0xFFE15656);
  static const critical500 = Color(0xFFD23A3A);
  static const critical600 = Color(0xFFB62B2B);
  static const critical700 = Color(0xFF96201F);
  static const critical800 = Color(0xFF7A1D1C);
  static const critical900 = Color(0xFF611A19);

  // ---- Informational (blue) --------------------------------------------
  static const info50 = Color(0xFFE7F1FC);
  static const info100 = Color(0xFFC9E1F9);
  static const info200 = Color(0xFF97C6F3);
  static const info300 = Color(0xFF5EA6EB);
  static const info400 = Color(0xFF2E88E0);
  static const info500 = Color(0xFF146FCB);
  static const info600 = Color(0xFF0E5AAA);
  static const info700 = Color(0xFF0C4A8C);
  static const info800 = Color(0xFF0B3D73);
  static const info900 = Color(0xFF0A325E);

  // ---- Neutral (grey, hue-biased toward brand ~275°) -------------------
  static const neutral0 = Color(0xFFFFFFFF);
  static const neutral50 = Color(0xFFF7F7FB);
  static const neutral100 = Color(0xFFEFEFF5);
  static const neutral200 = Color(0xFFE2E2EC);
  static const neutral300 = Color(0xFFCBCBD9);
  static const neutral400 = Color(0xFFA0A0B4);
  static const neutral500 = Color(0xFF75758C);
  static const neutral600 = Color(0xFF565669);
  static const neutral700 = Color(0xFF40404F);
  static const neutral800 = Color(0xFF2A2A36);
  static const neutral900 = Color(0xFF181822);

  // ===================================================================
  // SEMANTIC ALIASES — reach for these in widgets, not the raw ramps
  // ===================================================================

  // Surfaces & structure
  static const bg = neutral50; // app canvas
  static const surface = neutral0; // cards, sheets
  static const surfaceSunken = neutral100; // wells, input backgrounds
  static const border = neutral200; // hairlines, card edge
  static const borderStrong = neutral300; // input outline
  static const overlay = Color(0x7A181822); // scrim behind sheets (48%)

  // Text
  static const textPrimary = neutral900;
  static const textSecondary = neutral600;
  static const textTertiary = neutral500;
  static const textDisabled = neutral400;
  static const textOnBrand = neutral0;
  static const textLink = brand600;
  static const textLinkHover = brand700;

  // Brand roles
  static const brand = brand600;
  static const brandHover = brand700;
  static const brandSoft = brand50; // tinted bg
  static const brandSoftBorder = brand100;
  static const navActive = brand600;
  static const navInactive = neutral400;
  static const focusRing = brand400;

  // Status: fill (solid) / text (on soft bg) / soft (tinted bg) / border
  static const successFill = success600;
  static const successText = success700;
  static const successSoft = success50;
  static const successBorder = success200;

  static const warningFill = warning500;
  static const warningText = warning700;
  static const warningSoft = warning50;
  static const warningBorder = warning200;

  static const criticalFill = critical600;
  static const criticalText = critical700;
  static const criticalSoft = critical50;
  static const criticalBorder = critical200;

  static const infoFill = info600;
  static const infoText = info700;
  static const infoSoft = info50;
  static const infoBorder = info200;

  static const neutralFill = neutral600;
  static const neutralText = neutral700;
  static const neutralSoft = neutral100;
  static const neutralChipBorder = neutral200;

  // Verdict (apply / stretch / skip) — Brick 5 re-rank verdicts
  static const verdictApply = success600;
  static const verdictStretch = warning500;
  static const verdictSkip = critical600;

  // Guardrail (pass / fail) — Brick 6 anti-fabrication check
  static const guardrailPass = success600;
  static const guardrailFail = critical600;
  static const guardrailFailHighlight = critical100; // diff text bg

  // Kanban stage (6 states) — Brick 7 pipeline
  static const stageNew = neutral500;
  static const stageApplied = info600;
  static const stageReplied = info500;
  static const stageInterview = info700;
  static const stageOffer = success600;
  static const stageRejected = critical600;
}

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
  static const bottomNavH = 56.0; // AppShell bottom bar height
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
// Dart note: these are getters (not `static const`) because
// GoogleFonts.plusJakartaSans() is a function call, not a compile-time
// constant — the FlutterFlow equivalent is picking a Google Font by
// name in the font-family dropdown; here we call the loader ourselves.
// ---------------------------------------------------------------------
class AppTypography {
  AppTypography._();

  static TextStyle get display => GoogleFonts.plusJakartaSans(
    fontSize: 32,
    height: 38 / 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02 * 32,
    color: AppColors.textPrimary,
  );

  static TextStyle get heading => GoogleFonts.plusJakartaSans(
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.01 * 22,
    color: AppColors.textPrimary,
  );

  static TextStyle get headingSm => GoogleFonts.plusJakartaSans(
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static TextStyle get title => GoogleFonts.plusJakartaSans(
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static TextStyle get body => GoogleFonts.plusJakartaSans(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodyStrong => body.copyWith(fontWeight: FontWeight.w600);

  static TextStyle get bodySm => GoogleFonts.plusJakartaSans(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  static TextStyle get caption => GoogleFonts.plusJakartaSans(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  // Pair with `.toUpperCase()` at the call site — CSS text-transform has
  // no Dart TextStyle equivalent, it has to be applied to the string.
  static TextStyle get label => GoogleFonts.plusJakartaSans(
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.04 * 11,
    color: AppColors.textSecondary,
  );

  static TextStyle get monoData => GoogleFonts.jetBrainsMono(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.01 * 14,
    color: AppColors.textPrimary,
  );
}
