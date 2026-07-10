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
  final double? salaryMin;
  final double? salaryMax;

  Job({
    required this.id,
    required this.source,
    required this.title,
    this.company,
    this.location,
    this.redirectUrl,
    this.postedAt,
    this.salaryMin,
    this.salaryMax,
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
      salaryMin: (json['salary_min'] as num?)?.toDouble(),
      salaryMax: (json['salary_max'] as num?)?.toDouble(),
    );
  }

  /// Compact salary range for [JobCard]'s mono-data slot, e.g. "$145K–$180K".
  /// Null when the source didn't report a salary (common — not every posting
  /// includes one).
  String? get salaryLabel {
    if (salaryMin == null && salaryMax == null) return null;
    String fmt(double v) => '\$${(v / 1000).round()}K';
    if (salaryMin != null && salaryMax != null) return '${fmt(salaryMin!)}–${fmt(salaryMax!)}';
    return fmt((salaryMin ?? salaryMax)!);
  }

  /// Relative posted-date label for [JobCard], e.g. "2 days ago".
  String? get postedAtLabel {
    final d = postedAt;
    if (d == null) return null;
    final diff = DateTime.now().difference(d);
    if (diff.inDays >= 1) return '${diff.inDays}d ago';
    if (diff.inHours >= 1) return '${diff.inHours}h ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
    return 'just now';
  }
}
