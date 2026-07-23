import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

/// One cached payload + when it was written. `isStale` marks entries older
/// than 24h: still painted (stale beats blank), but callers must treat the
/// background revalidation as mandatory, not best-effort.
class CacheEntry<T> {
  const CacheEntry({required this.data, required this.cachedAt});

  final T data;
  final DateTime cachedAt;

  static const staleAfter = Duration(hours: 24);
  bool get isStale => DateTime.now().difference(cachedAt) > staleAfter;
}

/// Phase 5: stale-while-revalidate cache over SharedPreferences.
///
/// Pattern per screen: paint cached data instantly if present (no
/// skeleton) → fetch fresh in the background → update cache + UI → on
/// failure keep the cached paint and show a "Showing saved data" banner.
///
/// Every key is namespaced by the signed-in user's id (`<userId>:matches`)
/// so switching accounts can never paint the previous user's data, and
/// [clearForUser] wipes a user's entries on sign-out. Never cache auth
/// tokens (Supabase owns those), task statuses, or anything mid-mutation.
class CacheService {
  CacheService._();
  static final CacheService instance = CacheService._();

  /// Cache keys in one place so bodies and clearForUser can't drift.
  static const keyProfile = 'profile';
  static const keyMatches = 'matches';
  static const keyJobs = 'jobs';
  static const keyApplications = 'applications';
  static const keyCostStats = 'cost_stats';
  static const keyActivity = 'activity';
  static const allKeys = [keyProfile, keyMatches, keyJobs, keyApplications, keyCostStats, keyActivity];

  /// Phase 14 (ADR-028): passive refresh triggers (tab switch, app resume,
  /// the matching loading screen's background kick-off) treat cache younger
  /// than this as fresh enough to skip the network call entirely. Explicit
  /// pull-to-refresh ignores this and always refetches — see [RefreshThrottle].
  static const freshFor = Duration(minutes: 5);

  /// Phase 2: the app-wide theme mode is a **device-level** preference, so it
  /// is stored un-namespaced (survives sign-out, applies before any user is
  /// known). Still the same SharedPreferences layer — no second storage layer.
  /// The `app:` prefix can never collide with a user id namespace (UUIDs), so
  /// [clearForUser] leaves it untouched.
  static const _keyThemeMode = 'app:theme_mode';

  Future<String?> readThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyThemeMode);
  }

  Future<void> writeThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, mode);
  }

  String? get _userId => Supabase.instance.client.auth.currentUser?.id;

  /// When the entry for [key] was last written, or null if there's no cache
  /// (or no signed-in user). Bodies use this both for the freshness gate and
  /// the "updated Xm ago" indicator. Cheap enough to call on every build.
  Future<DateTime?> cachedAtFor(String key) async {
    final userId = _userId;
    if (userId == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$userId:$key');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return DateTime.parse(decoded['cachedAt'] as String);
    } catch (_) {
      return null;
    }
  }

  /// True when [key] has a cache written within [within] (default
  /// [freshFor]). This is the ADR-028 gate a PASSIVE refresh checks before
  /// hitting the network: fresh → paint cache, skip the call. Absent cache is
  /// never "fresh", so the very first load always fetches.
  Future<bool> isFresh(String key, {Duration within = freshFor}) async {
    final cachedAt = await cachedAtFor(key);
    if (cachedAt == null) return false;
    return DateTime.now().difference(cachedAt) < within;
  }

  /// Reads one entry for the current user. [fromJson] converts the decoded
  /// JSON value (Map or List) back into T. Null = no cache / no user /
  /// unreadable entry (corrupt entries are treated as absent, not errors).
  Future<CacheEntry<T>?> read<T>(String key, T Function(dynamic json) fromJson) async {
    final userId = _userId;
    if (userId == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$userId:$key');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return CacheEntry(
        data: fromJson(decoded['data']),
        cachedAt: DateTime.parse(decoded['cachedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  /// Writes one entry for the current user. [jsonValue] must be
  /// json-encodable (Map/List of primitives — use the model's toJson).
  Future<void> write(String key, Object? jsonValue) async {
    final userId = _userId;
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$userId:$key',
      jsonEncode({'data': jsonValue, 'cachedAt': DateTime.now().toIso8601String()}),
    );
  }

  /// Sign-out hygiene, called from AuthGate: drop everything namespaced to
  /// this user so the next account starts cold.
  Future<void> clearForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((k) => k.startsWith('$userId:')).toList()) {
      await prefs.remove(key);
    }
  }
}
