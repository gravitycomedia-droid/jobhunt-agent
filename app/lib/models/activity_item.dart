/// One row from GET /stats/activity — "what the agent did on your
/// behalf" (server/services/activity.py). `type` drives which icon/color
/// [ActivityLogScreen] and Home's "Recent activity" section pick locally
/// (`stage_change`, `followup`, or `tailored`) — same pattern as
/// [StatusPill]'s stage map, so color decisions stay in Dart rather than
/// arriving as hex strings from the server.
class ActivityItem {
  final String type;
  final String? stage;
  final String title;
  final String detail;
  final DateTime timestamp;

  ActivityItem({required this.type, this.stage, required this.title, required this.detail, required this.timestamp});

  factory ActivityItem.fromJson(Map<String, dynamic> json) {
    return ActivityItem(
      type: json['type'] as String,
      stage: json['stage'] as String?,
      title: json['title'] as String,
      detail: json['detail'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}
