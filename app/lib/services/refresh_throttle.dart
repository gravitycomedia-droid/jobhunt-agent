/// Phase 14 (ADR-028): client-side refresh throttling helpers, shared by every
/// tab body so the behavior is identical across Home, Jobs, Matches, and
/// Applications rather than re-implemented four slightly-different ways.
///
/// Two separate concerns live here:
///  - [RefreshThrottle] debounces the *explicit* pull-to-refresh gesture, so a
///    user who yanks the list three times in a second fires ONE network call,
///    not three. It does NOT impose the 5-minute freshness window — a pull
///    always refetches (that's what the gesture means); it only collapses a
///    rapid burst of pulls.
///  - [lastUpdatedLabel] formats a cache timestamp as "updated just now" /
///    "updated 3m ago" so the 5-minute passive window isn't invisible to the
///    user (ADR-028 acceptance criterion).
library;

/// Per-body debouncer for pull-to-refresh. One instance per tab body; call
/// [shouldRun] at the top of the refresh handler and bail if it returns false.
class RefreshThrottle {
  RefreshThrottle({this.cooldown = const Duration(seconds: 3)});

  /// How long after a fired refresh further pulls are ignored. Short — this is
  /// only meant to swallow accidental double-pulls, not to enforce a policy.
  final Duration cooldown;

  DateTime? _lastRun;

  /// True if a refresh may run now (and records this as the latest run); false
  /// if we're still inside the cooldown from the previous pull.
  bool shouldRun() {
    final now = DateTime.now();
    if (_lastRun != null && now.difference(_lastRun!) < cooldown) return false;
    _lastRun = now;
    return true;
  }
}

/// "updated just now" / "updated 5m ago" / "updated 2h ago" from a cache
/// timestamp. Null timestamp → null (nothing to show yet).
String? lastUpdatedLabel(DateTime? cachedAt) {
  if (cachedAt == null) return null;
  final diff = DateTime.now().difference(cachedAt);
  if (diff.inSeconds < 45) return 'Updated just now';
  if (diff.inMinutes < 60) return 'Updated ${diff.inMinutes}m ago';
  if (diff.inHours < 24) return 'Updated ${diff.inHours}h ago';
  return 'Updated ${diff.inDays}d ago';
}
