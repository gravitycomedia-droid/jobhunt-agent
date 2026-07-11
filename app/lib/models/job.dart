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
  final String? salaryCurrency; // ISO 4217, e.g. "INR" — Phase 1D

  /// Phase 5: exact server JSON, cached verbatim for round-tripping.
  final Map<String, dynamic> raw;

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
    this.salaryCurrency,
    this.raw = const {},
  });

  factory Job.fromJson(Map<String, dynamic> json) {
    return Job(
      raw: json,
      id: json['id'] as String,
      source: json['source'] as String,
      title: json['title'] as String,
      company: json['company'] as String?,
      location: json['location'] as String?,
      redirectUrl: json['redirect_url'] as String?,
      postedAt: json['posted_at'] == null ? null : DateTime.parse(json['posted_at'] as String),
      salaryMin: (json['salary_min'] as num?)?.toDouble(),
      salaryMax: (json['salary_max'] as num?)?.toDouble(),
      salaryCurrency: json['salary_currency'] as String?,
    );
  }

  /// Compact salary range for [JobCard]'s mono-data slot, formatted in the
  /// posting's actual currency (Phase 1D — never assume "$"): INR uses the
  /// Indian lakh convention ("₹20L–₹40L"), other known currencies get their
  /// symbol + K, unknown/missing currency shows the bare amount.
  String? get salaryLabel {
    if (salaryMin == null && salaryMax == null) return null;
    String fmt(double v) {
      if (salaryCurrency == 'INR') {
        // Lakh = 100,000. Below 1L (rare, likely monthly) show thousands.
        if (v >= 100000) {
          final lakhs = v / 100000;
          final label = lakhs >= 10 ? lakhs.round().toString() : lakhs.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
          return '₹${label}L';
        }
        return '₹${(v / 1000).round()}K';
      }
      const symbols = {'USD': '\$', 'GBP': '£', 'EUR': '€', 'AUD': 'A\$', 'CAD': 'C\$', 'SGD': 'S\$'};
      final symbol = symbols[salaryCurrency];
      final amount = '${(v / 1000).round()}K';
      // Unknown currency: show the code, not a wrong symbol.
      if (symbol == null) return salaryCurrency == null ? amount : '$salaryCurrency $amount';
      return '$symbol$amount';
    }

    if (salaryMin != null && salaryMax != null) return '${fmt(salaryMin!)}–${fmt(salaryMax!)}';
    return fmt((salaryMin ?? salaryMax)!);
  }

  /// Relative posted-date label for [JobCard], e.g. "2 days ago". Phase 1D:
  /// a missing or implausible date (> 1 year, i.e. predates the freshness
  /// filter or is source garbage) reads "date unknown", never "2591d ago".
  String? get postedAtLabel {
    final d = postedAt;
    if (d == null) return 'date unknown';
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 365) return 'date unknown';
    if (diff.inDays >= 1) return '${diff.inDays}d ago';
    if (diff.inHours >= 1) return '${diff.inHours}h ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
    return 'just now';
  }
}
