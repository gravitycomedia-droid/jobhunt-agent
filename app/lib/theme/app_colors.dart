import 'package:flutter/material.dart';

/// Phase 2 (frontend rebuild v2) — the semantic token layer from the design
/// bundle's `FLUTTER_GUIDE.md` §1, exposed as a [ThemeExtension] so
/// `Theme.of(context).extension<AppColors>()!` swaps automatically with the
/// active (light/dark) theme.
///
/// This is deliberately a *different* class from the legacy palette in
/// `app_tokens.dart` (which is also called `AppColors`, but is a static
/// light-only scale). The two coexist during the phased migration: new screens
/// and the signature widgets read these role-based tokens via `context.c`;
/// legacy screens keep using `app_tokens.dart` until they migrate. The legacy
/// file is deleted in Phase 10. **Never import both unprefixed in one file** —
/// the class names collide by design of the migration, not by accident.
///
/// Dart note: a `ThemeExtension` must implement [copyWith] and [lerp] so
/// Flutter can animate between themes; that's the boilerplate below.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color ink, inkSoft, inkFaint, paper, surface, surface2, accent,
      accentSoft, border, success, warning, critical, info;

  const AppColors({
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.paper,
    required this.surface,
    required this.surface2,
    required this.accent,
    required this.accentSoft,
    required this.border,
    required this.success,
    required this.warning,
    required this.critical,
    required this.info,
  });

  static const light = AppColors(
    ink: Color(0xFF14141C),
    inkSoft: Color(0xFF5B5B66),
    inkFaint: Color(0xFF9A9AA3),
    paper: Color(0xFFFAFAF9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F4F3),
    accent: Color(0xFF5750E8),
    accentSoft: Color(0x1A5750E8),
    border: Color(0xFFE7E7EA),
    success: Color(0xFF2E9E6B),
    warning: Color(0xFFB9852F),
    critical: Color(0xFFD2544B),
    info: Color(0xFF4B78C9),
  );

  static const dark = AppColors(
    ink: Color(0xFFF2F2F5),
    inkSoft: Color(0xFFA7A7B2),
    inkFaint: Color(0xFF6A6A76),
    paper: Color(0xFF0E0E13),
    surface: Color(0xFF17171F),
    surface2: Color(0xFF1E1E28),
    accent: Color(0xFF7A73FF),
    accentSoft: Color(0x267A73FF),
    border: Color(0xFF26262F),
    success: Color(0xFF3FB57F),
    warning: Color(0xFFD6A24E),
    critical: Color(0xFFE56A61),
    info: Color(0xFF6E97DE),
  );

  /// The fit-gauge arc gradient — identical in both themes (orange→amber→green).
  static const gaugeGradient = [
    Color(0xFFF5842B),
    Color(0xFFE0B33A),
    Color(0xFF2E9E6B),
  ];

  @override
  AppColors copyWith({
    Color? ink,
    Color? inkSoft,
    Color? inkFaint,
    Color? paper,
    Color? surface,
    Color? surface2,
    Color? accent,
    Color? accentSoft,
    Color? border,
    Color? success,
    Color? warning,
    Color? critical,
    Color? info,
  }) =>
      AppColors(
        ink: ink ?? this.ink,
        inkSoft: inkSoft ?? this.inkSoft,
        inkFaint: inkFaint ?? this.inkFaint,
        paper: paper ?? this.paper,
        surface: surface ?? this.surface,
        surface2: surface2 ?? this.surface2,
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        border: border ?? this.border,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        critical: critical ?? this.critical,
        info: info ?? this.info,
      );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      ink: l(ink, other.ink),
      inkSoft: l(inkSoft, other.inkSoft),
      inkFaint: l(inkFaint, other.inkFaint),
      paper: l(paper, other.paper),
      surface: l(surface, other.surface),
      surface2: l(surface2, other.surface2),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      border: l(border, other.border),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      critical: l(critical, other.critical),
      info: l(info, other.info),
    );
  }
}

/// Convenience accessor so widgets can write `context.c.accent` instead of
/// `Theme.of(context).extension<AppColors>()!.accent`.
extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>()!;
}
