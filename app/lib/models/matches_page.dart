import 'locked_match_item.dart';
import 'match_item.dart';

/// Plan 21: the whole GET /matches payload.
///
/// `data` used to be a bare array of matches; it's now an object so the gated
/// response can carry its locked teasers alongside the real ones. The
/// {"data": ..., "error": null} envelope is unchanged — only the shape inside
/// it grew.
class MatchesPage {
  final List<MatchItem> matches;

  /// Empty for an ungated profile (anyone on the `pro` tier — which today is
  /// everyone), so the Matches screen renders exactly as before for them.
  final List<LockedMatchItem> locked;

  /// How many full-analysis matches this profile gets, straight from the
  /// server so the tier/quota rules aren't reimplemented in Dart.
  final int effectiveMatchLimit;

  const MatchesPage({
    required this.matches,
    this.locked = const [],
    this.effectiveMatchLimit = 0,
  });

  bool get hasLocked => locked.isNotEmpty;

  /// Accepts BOTH response shapes on purpose.
  ///
  /// Before Plan 21 the server sent `data` as a bare array of matches; it now
  /// sends an object. A new build of this app can be on a phone while the old
  /// server is still live (the server deploy is a separate manual step), and
  /// during that window `as Map` would throw and take the whole Matches tab
  /// down. Reading a legacy array as "matches, nothing locked" degrades to
  /// exactly the pre-Plan-21 behaviour instead.
  factory MatchesPage.fromAny(dynamic data) {
    if (data is List) {
      return MatchesPage(
        matches: data.map((m) => MatchItem.fromJson((m as Map).cast<String, dynamic>())).toList(),
      );
    }
    return MatchesPage.fromJson((data as Map).cast<String, dynamic>());
  }

  factory MatchesPage.fromJson(Map<String, dynamic> json) => MatchesPage(
        matches: (json['matches'] as List? ?? const [])
            .map((m) => MatchItem.fromJson((m as Map).cast<String, dynamic>()))
            .toList(),
        locked: (json['locked'] as List? ?? const [])
            .map((m) => LockedMatchItem.fromJson((m as Map).cast<String, dynamic>()))
            .toList(),
        effectiveMatchLimit: (json['effective_match_limit'] as num?)?.toInt() ?? 0,
      );
}
