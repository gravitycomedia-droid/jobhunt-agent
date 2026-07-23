import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/match_item.dart';
import 'api_client.dart';
import 'cache_service.dart';
import 'task_center.dart';

/// Observable state for the ranked-matches feed. [matches] null = never loaded
/// this session (show the mascot loader, not an empty list); empty list =
/// loaded, genuinely no matches. [staleSince] is non-null only when a cached
/// list is painted but the last refresh failed — bodies show the stale banner.
class MatchFeedState {
  const MatchFeedState({this.matches, this.staleSince});
  final List<MatchItem>? matches;
  final DateTime? staleSince;

  MatchFeedState copyWith({
    List<MatchItem>? matches,
    DateTime? staleSince,
    bool clearStale = false,
  }) =>
      MatchFeedState(
        matches: matches ?? this.matches,
        staleSince: clearStale ? null : (staleSince ?? this.staleSince),
      );
}

/// Phase 2c (was a plain singleton): the single source of truth for the
/// ranked-matches list. Home's "N matches" stat and the Matches tab both render
/// literally the same [MatchFeedState.matches], so the two can never disagree.
///
/// A finished rerank or agent run means new `matches` rows — this notifier
/// listens to [taskCenterProvider] and refreshes itself when either completes,
/// instead of each screen polling on its own.
final matchFeedProvider =
    NotifierProvider<MatchFeed, MatchFeedState>(MatchFeed.new);

class MatchFeed extends Notifier<MatchFeedState> {
  final ApiClient _api = ApiClient();

  @override
  MatchFeedState build() {
    for (final kind in [TaskKind.rerank, TaskKind.pipeline]) {
      ref.listen(trackedTaskProvider((kind: kind, id: null)), (_, next) {
        if (next?.status == TrackedTaskStatus.done) unawaited(_refreshQuietly());
      });
    }
    return const MatchFeedState();
  }

  /// One shared definition of "a match the user sees": everything GET /matches
  /// returns, best-fit first. Deliberately NOT hiding 'skip' verdicts (the
  /// verdict pill communicates that; hiding rows caused count-vs-cards drift).
  List<MatchItem> _canonical(List<MatchItem> items) => items;

  /// Paint the cached list instantly (no skeleton) if one exists. Returns true
  /// if a cache was painted.
  Future<bool> loadFromCache() async {
    if (state.matches != null) return true; // already have data this session
    final entry = await CacheService.instance.read<List<MatchItem>>(
      CacheService.keyMatches,
      (json) => (json as List)
          .map((m) => MatchItem.fromJson((m as Map).cast<String, dynamic>()))
          .toList(),
    );
    if (entry == null || state.matches != null) return state.matches != null;
    state = MatchFeedState(matches: _canonical(entry.data), staleSince: entry.cachedAt);
    return true;
  }

  Future<List<MatchItem>> refresh({int limit = 50}) async {
    try {
      final items = _canonical(await _api.fetchMatches(limit: limit));
      state = MatchFeedState(matches: items);
      await CacheService.instance.write(CacheService.keyMatches, [for (final m in items) m.raw]);
      return items;
    } catch (_) {
      // Keep whatever is painted (possibly cached); mark it stale so the banner
      // shows, then rethrow for callers that surface errors.
      if (state.matches != null && state.staleSince == null) {
        state = state.copyWith(staleSince: DateTime.now());
      }
      rethrow;
    }
  }

  /// Fire-and-forget refresh used by the task-completion listener — swallows
  /// errors (the stale banner already communicates a failed refresh).
  Future<void> _refreshQuietly() async {
    try {
      await refresh();
    } catch (_) {}
  }

  /// Sign-out hygiene — next account must never see this user's matches.
  void reset() {
    state = const MatchFeedState();
  }
}
