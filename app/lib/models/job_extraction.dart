/// Add Job (frontend rebuild Phase 2) — mirrors server/models/job.py's
/// JobExtraction. Returned by POST /jobs/manual/parse for the user to
/// review/edit before POST /jobs/manual actually creates anything.
class JobExtraction {
  String title;
  String? company;
  String? location;
  String? description;
  double? salaryMin;
  double? salaryMax;

  JobExtraction({
    required this.title,
    this.company,
    this.location,
    this.description,
    this.salaryMin,
    this.salaryMax,
  });

  factory JobExtraction.fromJson(Map<String, dynamic> json) {
    return JobExtraction(
      title: json['title'] as String,
      company: json['company'] as String?,
      location: json['location'] as String?,
      description: json['description'] as String?,
      salaryMin: (json['salary_min'] as num?)?.toDouble(),
      salaryMax: (json['salary_max'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'company': company,
        'location': location,
        'description': description,
        'salary_min': salaryMin,
        'salary_max': salaryMax,
      };
}

/// POST /jobs/from-jd response — just enough to hand straight into
/// ResumeDiffScreen, which reuses the standard tailoring flow unchanged.
class JdResumeJob {
  final String jobId;
  final String jobTitle;

  const JdResumeJob({required this.jobId, required this.jobTitle});

  factory JdResumeJob.fromJson(Map<String, dynamic> json) {
    return JdResumeJob(jobId: json['job_id'] as String, jobTitle: json['job_title'] as String);
  }
}
