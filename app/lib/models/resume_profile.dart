/// Mirrors server/models/resume.py. One Dart class per Pydantic model —
/// same pattern as HealthStatus in Brick 1: a `fromJson` factory to parse,
/// and (new here) a `toJson` to send edits back on PATCH.
class ExperienceItem {
  String role;
  String company;
  String duration;
  List<String> bullets;

  ExperienceItem({
    required this.role,
    required this.company,
    required this.duration,
    required this.bullets,
  });

  factory ExperienceItem.fromJson(Map<String, dynamic> json) {
    return ExperienceItem(
      role: json['role'] as String,
      company: json['company'] as String,
      // The server allows duration/description/year to be null (a resume can
      // genuinely omit them) — `?? ''` gives the text field an empty string
      // to start from instead of crashing on the null.
      duration: json['duration'] as String? ?? '',
      bullets: (json['bullets'] as List).map((b) => b as String).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'company': company,
        'duration': duration,
        'bullets': bullets,
      };
}

class ProjectItem {
  String name;
  List<String> tech;
  String description;

  ProjectItem({required this.name, required this.tech, required this.description});

  factory ProjectItem.fromJson(Map<String, dynamic> json) {
    return ProjectItem(
      name: json['name'] as String,
      tech: (json['tech'] as List).map((t) => t as String).toList(),
      description: json['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'tech': tech,
        'description': description,
      };
}

class EducationItem {
  String degree;
  String institution;
  String year;

  EducationItem({required this.degree, required this.institution, required this.year});

  factory EducationItem.fromJson(Map<String, dynamic> json) {
    return EducationItem(
      degree: json['degree'] as String,
      institution: json['institution'] as String,
      year: json['year'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'degree': degree,
        'institution': institution,
        'year': year,
      };
}

/// The `?` on `headline` means "this can be null" — Dart's null safety makes
/// every field non-nullable by default, so any field that really can be
/// absent (like a resume with no headline) has to say so explicitly.
class ResumeProfile {
  final String id;
  String name;
  String? headline;
  List<String> skills;
  List<ExperienceItem> experience;
  List<ProjectItem> projects;
  List<EducationItem> education;

  /// Onboarding (frontend rebuild Phase 1) — set via PATCH
  /// /resume/profile/target-roles, not editable through this class's own
  /// [toJson] (that endpoint is intentionally separate; see
  /// server/routers/resume.py).
  List<String> targetRoles;
  double? minSalary;

  /// Phase 4 Settings screen — set via PATCH
  /// /resume/profile/notification-prefs, same "separate endpoint, not part
  /// of [toJson]" precedent as [targetRoles]/[minSalary] above.
  bool notifyAlerts;
  bool notifyFollowupNudge;

  /// Phase 3B: where the user is in onboarding (welcome/resume/review/
  /// student_info/roles/done) — AuthGate resumes the flow at exactly this
  /// step. Server bumps it forward as steps complete; skips PATCH it
  /// explicitly.
  String onboardingStep;

  /// Set via PATCH /resume/profile/student-info, same "separate endpoint,
  /// not part of [toJson]" precedent as [targetRoles]/notifications above.
  /// [usn] may also arrive pre-filled straight from the resume parser
  /// (services/llm.py extracts it when visible) before the user ever hits
  /// that endpoint.
  String? employmentType;
  String? usn;

  /// Phase 6 (§4.1) onboarding-fork facts, all set via their own dedicated
  /// endpoints (academics / experience / target-locations), never through this
  /// class's [toJson] — same "separate endpoint" precedent as [targetRoles].
  /// Student branch:
  String? branch;
  int? gradYear;
  double? cgpa;

  /// Professional branch:
  String? company;
  double? experienceYears;
  int? noticePeriodDays;

  /// Preferred cities (also read by the jobs filter/match paths).
  List<String> targetLocations;

  /// Migration 026 — the contact block printed at the top of a compiled résumé
  /// PDF. Pre-filled by the résumé parser when they're printed on the uploaded
  /// file, then editable from Settings → Contact details. Unlike the fields
  /// above these DO ride in [toJson] (PATCH /resume/profile owns them), because
  /// they're résumé content rather than onboarding state.
  String? email;
  String? phone;
  String? location;
  String? linkedinUrl;
  String? githubUrl;
  String? websiteUrl;

  /// Phase 5: exact server JSON, cached verbatim for round-tripping (the
  /// hand-written [toJson] below is the PATCH body — a subset, not a
  /// faithful copy, so it can't be used for caching).
  final Map<String, dynamic> raw;

  ResumeProfile({
    required this.id,
    required this.name,
    this.headline,
    required this.skills,
    required this.experience,
    required this.projects,
    required this.education,
    this.targetRoles = const [],
    this.minSalary,
    this.notifyAlerts = true,
    this.notifyFollowupNudge = true,
    this.onboardingStep = 'done',
    this.employmentType,
    this.usn,
    this.branch,
    this.gradYear,
    this.cgpa,
    this.company,
    this.experienceYears,
    this.noticePeriodDays,
    this.targetLocations = const [],
    this.email,
    this.phone,
    this.location,
    this.linkedinUrl,
    this.githubUrl,
    this.websiteUrl,
    this.raw = const {},
  });

  factory ResumeProfile.fromJson(Map<String, dynamic> json) {
    return ResumeProfile(
      raw: json,
      id: json['id'] as String,
      name: json['name'] as String,
      headline: json['headline'] as String?,
      skills: (json['skills'] as List).map((s) => s as String).toList(),
      experience: (json['experience'] as List)
          .map((e) => ExperienceItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      projects: (json['projects'] as List)
          .map((p) => ProjectItem.fromJson(p as Map<String, dynamic>))
          .toList(),
      education: (json['education'] as List)
          .map((ed) => EducationItem.fromJson(ed as Map<String, dynamic>))
          .toList(),
      targetRoles: (json['target_roles'] as List? ?? []).map((r) => r as String).toList(),
      minSalary: (json['min_salary'] as num?)?.toDouble(),
      notifyAlerts: (json['notification_prefs'] as Map<String, dynamic>?)?['alerts'] as bool? ?? true,
      notifyFollowupNudge: (json['notification_prefs'] as Map<String, dynamic>?)?['followup_nudge'] as bool? ?? true,
      // Missing column (pre-migration-011 server) reads as done — never
      // trap an existing user back in onboarding.
      onboardingStep: json['onboarding_step'] as String? ?? 'done',
      employmentType: json['employment_type'] as String?,
      usn: json['usn'] as String?,
      branch: json['branch'] as String?,
      gradYear: (json['grad_year'] as num?)?.toInt(),
      cgpa: (json['cgpa'] as num?)?.toDouble(),
      company: json['company'] as String?,
      experienceYears: (json['experience_years'] as num?)?.toDouble(),
      noticePeriodDays: (json['notice_period_days'] as num?)?.toInt(),
      targetLocations: (json['target_locations'] as List? ?? []).map((l) => l as String).toList(),
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      location: json['location'] as String?,
      linkedinUrl: json['linkedin_url'] as String?,
      githubUrl: json['github_url'] as String?,
      websiteUrl: json['website_url'] as String?,
    );
  }

  /// Phase 5 (§4.11): résumé-completion for the Profile bar. A DETERMINISTIC
  /// count of which core résumé sections the user has actually filled — code,
  /// never an LLM guess (Golden Rule 2). The fraction of these seven signals
  /// present, as a whole percent. Pure, so it's a clean candidate to lift
  /// server-side later without changing the meaning.
  int get completionPercent {
    final signals = <bool>[
      name.trim().isNotEmpty,
      headline?.trim().isNotEmpty ?? false,
      skills.isNotEmpty,
      experience.isNotEmpty,
      projects.isNotEmpty,
      education.isNotEmpty,
      targetRoles.isNotEmpty,
    ];
    return ((signals.where((s) => s).length / signals.length) * 100).round();
  }

  /// Sent as the PATCH body — server accepts partial updates, but we always
  /// send the full edited profile since the review screen edits everything.
  Map<String, dynamic> toJson() => {
        'name': name,
        'headline': headline,
        'skills': skills,
        'experience': experience.map((e) => e.toJson()).toList(),
        'projects': projects.map((p) => p.toJson()).toList(),
        'education': education.map((ed) => ed.toJson()).toList(),
        ...contactJson(),
      };

  /// The migration-026 contact fields, **omitting the ones that are null**.
  ///
  /// The omission matters: the server's PATCH uses `exclude_unset`, but a JSON
  /// `null` counts as set, so spreading nulls here would let the résumé-review
  /// screen — which never shows these fields — silently wipe a LinkedIn the
  /// user typed in Settings. To actually clear one, send `''` (the PDF treats
  /// blank as absent), which is what the Settings editor does.
  Map<String, dynamic> contactJson() => {
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (location != null) 'location': location,
        if (linkedinUrl != null) 'linkedin_url': linkedinUrl,
        if (githubUrl != null) 'github_url': githubUrl,
        if (websiteUrl != null) 'website_url': websiteUrl,
      };
}
