/// One entry from GET /stats/skill-growth — a skill clustered from the
/// caller's real match gaps, with a real "N of M matches" frequency
/// (computed server-side, never a fabricated percentage) and
/// LLM-suggested courses/projects. See server/services/skill_growth.py.
class SkillCourse {
  final String title;
  final String provider;
  final String duration;

  SkillCourse({required this.title, required this.provider, required this.duration});

  factory SkillCourse.fromJson(Map<String, dynamic> json) {
    return SkillCourse(
      title: json['title'] as String,
      provider: json['provider'] as String,
      duration: json['duration'] as String,
    );
  }
}

class SkillProject {
  final String title;
  final String impact;

  SkillProject({required this.title, required this.impact});

  factory SkillProject.fromJson(Map<String, dynamic> json) {
    return SkillProject(title: json['title'] as String, impact: json['impact'] as String);
  }
}

class SkillGrowthItem {
  final String skill;
  final String reason;
  final String frequencyLabel;
  final List<SkillCourse> courses;
  final List<SkillProject> projects;

  SkillGrowthItem({
    required this.skill,
    required this.reason,
    required this.frequencyLabel,
    required this.courses,
    required this.projects,
  });

  factory SkillGrowthItem.fromJson(Map<String, dynamic> json) {
    return SkillGrowthItem(
      skill: json['skill'] as String,
      reason: json['reason'] as String,
      frequencyLabel: json['frequency_label'] as String,
      courses: (json['courses'] as List).map((c) => SkillCourse.fromJson(c as Map<String, dynamic>)).toList(),
      projects: (json['projects'] as List).map((p) => SkillProject.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }
}
