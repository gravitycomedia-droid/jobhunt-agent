/// Mirrors the `jobs` table / server/models/job.py. Read-only from the app's
/// side for now (Brick 3) — no toJson needed since we never edit a job.
class Job {
  final String id;
  final String source;
  final String title;
  final String? company;
  final String? location;
  final String? redirectUrl;
  final DateTime? postedAt;

  Job({
    required this.id,
    required this.source,
    required this.title,
    this.company,
    this.location,
    this.redirectUrl,
    this.postedAt,
  });

  factory Job.fromJson(Map<String, dynamic> json) {
    return Job(
      id: json['id'] as String,
      source: json['source'] as String,
      title: json['title'] as String,
      company: json['company'] as String?,
      location: json['location'] as String?,
      redirectUrl: json['redirect_url'] as String?,
      postedAt: json['posted_at'] == null ? null : DateTime.parse(json['posted_at'] as String),
    );
  }
}
