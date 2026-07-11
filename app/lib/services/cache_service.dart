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

  String? get _userId => Supabase.instance.client.auth.currentUser?.id;

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
