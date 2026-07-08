/// Mirrors the server's GET /health response shape:
/// {"data": {"status": "ok", "time": "2026-07-08T12:00:00Z"}, "error": null}
///
/// In FlutterFlow you'd get this for free from an API call's "JSON Path"
/// response mapping. Here we write it by hand: one Dart class per JSON shape,
/// with a `fromJson` factory that does the parsing.
class HealthStatus {
  final String status;
  final DateTime time;

  HealthStatus({required this.status, required this.time});

  factory HealthStatus.fromJson(Map<String, dynamic> json) {
    return HealthStatus(
      status: json['status'] as String,
      time: DateTime.parse(json['time'] as String),
    );
  }
}
