import 'package:flutter/material.dart';

import 'cache_service.dart';

/// Owns the app-wide light/dark/system theme mode.
///
/// A plain [ValueNotifier] singleton (pre-Riverpod, introduced in Phase 2a);
/// `main.dart` rebuilds the [MaterialApp] through a `ValueListenableBuilder` on
/// [mode]. The chosen mode persists through [CacheService] — the existing
/// SharedPreferences layer, no second storage layer — and is restored by [load]
/// before `runApp` so the first frame is already in the right theme.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);

  Future<void> load() async {
    mode.value = _parse(await CacheService.instance.readThemeMode());
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    await CacheService.instance.writeThemeMode(value.name);
  }

  ThemeMode _parse(String? name) {
    switch (name) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
