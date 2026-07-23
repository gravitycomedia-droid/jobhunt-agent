/// GET /stats/score-history (frontend rebuild v2, Phase 4 backend / R-D).
///
/// Backs Home's fit-gauge delta chip. The server diffs the newest score
/// snapshot against the latest one at least 24h older (day-over-day), so
/// [delta] is null until two snapshots that far apart exist — the client
/// then HIDES the chip entirely rather than paint a fabricated `+0`
/// (§4.2). See server/services/score_history.py.
class ScorePoint {
  final DateTime? capturedAt;
  final int? topFitScore;
  final double? avgFitScore;
  final int? matchCount;

  const ScorePoint({this.capturedAt, this.topFitScore, this.avgFitScore, this.matchCount});

  factory ScorePoint.fromJson(Map<String, dynamic> json) {
    final ts = json['captured_at'];
    return ScorePoint(
      capturedAt: ts == null ? null : DateTime.tryParse(ts as String),
      topFitScore: (json['top_fit_score'] as num?)?.toInt(),
      avgFitScore: (json['avg_fit_score'] as num?)?.toDouble(),
      matchCount: (json['match_count'] as num?)?.toInt(),
    );
  }
}

/// Day-over-day movement. Non-null only when a ≥24h-older snapshot exists.
class ScoreDelta {
  final int topFit;
  final double avgFit;

  const ScoreDelta({required this.topFit, required this.avgFit});

  factory ScoreDelta.fromJson(Map<String, dynamic> json) => ScoreDelta(
        topFit: (json['top_fit'] as num).toInt(),
        avgFit: (json['avg_fit'] as num).toDouble(),
      );
}

class ScoreHistory {
  final ScorePoint? current;

  /// null → the caller must hide the delta chip (never render a fabricated 0).
  final ScoreDelta? delta;
  final List<ScorePoint> history;

  const ScoreHistory({this.current, this.delta, this.history = const []});

  factory ScoreHistory.fromJson(Map<String, dynamic> json) {
    final current = json['current'];
    final delta = json['delta'];
    return ScoreHistory(
      current: current == null ? null : ScorePoint.fromJson((current as Map).cast<String, dynamic>()),
      delta: delta == null ? null : ScoreDelta.fromJson((delta as Map).cast<String, dynamic>()),
      history: ((json['history'] as List?) ?? const [])
          .map((p) => ScorePoint.fromJson((p as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}
