import 'package:flutter/foundation.dart';

import '../models/match_item.dart';
import 'api_client.dart';
import 'cache_service.dart';
import 'task_center.dart';

/// Phase 1C: the single source of truth for the ranked-matches list.
///
/// Home's "N matches" stat and the Matches tab used to each fetch and hold
/// their own copy of GET /matches — Home mounted once inside the
/// IndexedStack and never refetched after a rerank landed, so its count
/// drifted from what the Matches tab was actually rendering. Both now
/// render literally the same [matches] list (Home's stat is its `.length`),
/// so the two can never disagree.
///
/// The canonical filter lives in [_canonical] — if we ever decide to hide
/// 'skip' verdicts, change it there and both surfaces stay in lockstep.
class MatchFeed {
  MatchFeed._() {
    // A finished rerank or agent run means new rows in `matches` — refresh
    // every subscriber at once instead of each screen polling on its own.
    for (final kind in [TaskKind.rerank, TaskKind.pipeline]) {
      TaskCenter.instance.notifierFor(kind).addListener(() {
        final task = TaskCenter.instance.notifierFor(kind).value;
        if (task?.status == TrackedTaskStatus.done) refresh();
      });
    }
  }
  static final MatchFeed instance = MatchFeed._();

  final ApiClient _api = ApiClient();

  /// Null = never loaded this session (show skeletons); empty list = loaded,
  /// genuinely no matches.
  final ValueNotifier<List<MatchItem>?> matches = ValueNotifier(null);

  /// One shared definition of "a match the user sees" (Phase 1C contract).
  /// Today: everything GET /matches returns, best-fit first. Deliberately
  /// NOT filtering 'skip' verdicts silently — the verdict pill communicates
  /// that; hiding rows is what caused count-vs-cards confusion before.
  List<MatchItem> _canonical(List<MatchItem> items) => items;

  /// Phase 5: when the cached list was painted but the fresh fetch failed,
  /// this holds the cache timestamp so bodies can show the stale banner.
  /// Null whenever the data on screen is fresh (or absent).
  final ValueNotifier<DateTime?> staleSince = ValueNotifier(null);

  /// Phase 5 stale-while-revalidate: paint the cached list instantly (no
  /// skeleton) if one exists. Returns true if a cache was painted.
  Future<bool> loadFromCache() async {
    if (matches.value != null) return true; // already have data this session
    final entry = await CacheService.instance.read<List<MatchItem>>(
      CacheService.keyMatches,
      (json) => (json as List).map((m) => MatchItem.fromJson((m as Map).cast<String, dynamic>())).toList(),
    );
    if (entry == null || matches.value != null) return matches.value != null;
    matches.value = _canonical(entry.data);
    staleSince.value = entry.cachedAt;
    return true;
  }

  Future<List<MatchItem>> refresh({int limit = 50}) async {
    try {
      final items = _canonical(await _api.fetchMatches(limit: limit));
      matches.value = items;
      staleSince.value = null;
      await CacheService.instance.write(CacheService.keyMatches, [for (final m in items) m.raw]);
      return items;
    } catch (_) {
      // Keep whatever is painted (possibly cached); mark it stale so the
      // banner shows, then rethrow for callers that surface errors.
      if (matches.value != null && staleSince.value == null) {
        staleSince.value = DateTime.now(); // fresh-as-of-last-success unknown; now is the honest floor
      }
      rethrow;
    }
  }

  /// Sign-out hygiene — next account must never see this user's matches.
  void reset() {
    matches.value = null;
    staleSince.value = null;
  }
}
