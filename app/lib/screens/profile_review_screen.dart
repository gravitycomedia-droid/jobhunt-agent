import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';

/// Small controller bundles so each list item (one experience entry, one
/// project, one education entry) owns its own TextEditingControllers instead
/// of us re-reading/re-writing strings on every keystroke. This is the Dart
/// equivalent of a repeating FlutterFlow component inside a ListView builder.
class _ExperienceControllers {
  final role = TextEditingController();
  final company = TextEditingController();
  final duration = TextEditingController();
  final bullets = TextEditingController(); // one bullet per line

  _ExperienceControllers.fromItem(ExperienceItem item) {
    role.text = item.role;
    company.text = item.company;
    duration.text = item.duration;
    bullets.text = item.bullets.join('\n');
  }

  ExperienceItem toItem() => ExperienceItem(
        role: role.text.trim(),
        company: company.text.trim(),
        duration: duration.text.trim(),
        bullets: bullets.text.split('\n').map((b) => b.trim()).where((b) => b.isNotEmpty).toList(),
      );

  void dispose() {
    role.dispose();
    company.dispose();
    duration.dispose();
    bullets.dispose();
  }
}

class _ProjectControllers {
  final name = TextEditingController();
  final tech = TextEditingController(); // comma-separated
  final description = TextEditingController();

  _ProjectControllers.fromItem(ProjectItem item) {
    name.text = item.name;
    tech.text = item.tech.join(', ');
    description.text = item.description;
  }

  ProjectItem toItem() => ProjectItem(
        name: name.text.trim(),
        tech: tech.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
        description: description.text.trim(),
      );

  void dispose() {
    name.dispose();
    tech.dispose();
    description.dispose();
  }
}

class _EducationControllers {
  final degree = TextEditingController();
  final institution = TextEditingController();
  final year = TextEditingController();

  _EducationControllers.fromItem(EducationItem item) {
    degree.text = item.degree;
    institution.text = item.institution;
    year.text = item.year;
  }

  EducationItem toItem() => EducationItem(
        degree: degree.text.trim(),
        institution: institution.text.trim(),
        year: year.text.trim(),
      );

  void dispose() {
    degree.dispose();
    institution.dispose();
    year.dispose();
  }
}

class ProfileReviewScreen extends StatefulWidget {
  final ResumeProfile profile;

  const ProfileReviewScreen({super.key, required this.profile});

  @override
  State<ProfileReviewScreen> createState() => _ProfileReviewScreenState();
}

class _ProfileReviewScreenState extends State<ProfileReviewScreen> {
  final ApiClient _apiClient = ApiClient();

  late final TextEditingController _name;
  late final TextEditingController _headline;
  late final TextEditingController _skills;
  late List<_ExperienceControllers> _experience;
  late List<_ProjectControllers> _projects;
  late List<_EducationControllers> _education;

  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name = TextEditingController(text: p.name);
    _headline = TextEditingController(text: p.headline ?? '');
    _skills = TextEditingController(text: p.skills.join(', '));
    _experience = p.experience.map((e) => _ExperienceControllers.fromItem(e)).toList();
    _projects = p.projects.map((pr) => _ProjectControllers.fromItem(pr)).toList();
    _education = p.education.map((ed) => _EducationControllers.fromItem(ed)).toList();
  }

  @override
  void dispose() {
    _name.dispose();
    _headline.dispose();
    _skills.dispose();
    for (final e in _experience) {
      e.dispose();
    }
    for (final p in _projects) {
      p.dispose();
    }
    for (final ed in _education) {
      ed.dispose();
    }
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    final edited = ResumeProfile(
      id: widget.profile.id,
      name: _name.text.trim(),
      headline: _headline.text.trim().isEmpty ? null : _headline.text.trim(),
      skills: _skills.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      experience: _experience.map((e) => e.toItem()).toList(),
      projects: _projects.map((p) => p.toItem()).toList(),
      education: _education.map((ed) => ed.toItem()).toList(),
    );

    try {
      await _apiClient.updateProfile(edited);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('Basics'),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 12),
          TextField(controller: _headline, decoration: const InputDecoration(labelText: 'Headline')),
          const SizedBox(height: 12),
          TextField(
            controller: _skills,
            decoration: const InputDecoration(labelText: 'Skills (comma-separated)'),
            maxLines: 2,
          ),
          const SizedBox(height: 24),
          _sectionLabel('Experience'),
          ..._experience.asMap().entries.map((entry) => _experienceCard(entry.key, entry.value)),
          OutlinedButton.icon(
            onPressed: () => setState(() => _experience.add(
                  _ExperienceControllers.fromItem(
                    ExperienceItem(role: '', company: '', duration: '', bullets: []),
                  ),
                )),
            icon: const Icon(Icons.add),
            label: const Text('Add experience'),
          ),
          const SizedBox(height: 24),
          _sectionLabel('Projects'),
          ..._projects.asMap().entries.map((entry) => _projectCard(entry.key, entry.value)),
          OutlinedButton.icon(
            onPressed: () => setState(() => _projects.add(
                  _ProjectControllers.fromItem(ProjectItem(name: '', tech: [], description: '')),
                )),
            icon: const Icon(Icons.add),
            label: const Text('Add project'),
          ),
          const SizedBox(height: 24),
          _sectionLabel('Education'),
          ..._education.asMap().entries.map((entry) => _educationCard(entry.key, entry.value)),
          OutlinedButton.icon(
            onPressed: () => setState(() => _education.add(
                  _EducationControllers.fromItem(
                    EducationItem(degree: '', institution: '', year: ''),
                  ),
                )),
            icon: const Icon(Icons.add),
            label: const Text('Add education'),
          ),
          const SizedBox(height: 24),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
            ),
          FilledButton(
            onPressed: _isSaving ? null : _confirm,
            child: _isSaving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Confirm'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _experienceCard(int index, _ExperienceControllers c) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: c.role, decoration: const InputDecoration(labelText: 'Role'))),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    c.dispose();
                    _experience.removeAt(index);
                  }),
                ),
              ],
            ),
            TextField(controller: c.company, decoration: const InputDecoration(labelText: 'Company')),
            TextField(controller: c.duration, decoration: const InputDecoration(labelText: 'Duration')),
            TextField(
              controller: c.bullets,
              decoration: const InputDecoration(labelText: 'Bullets (one per line)'),
              maxLines: null,
              minLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _projectCard(int index, _ProjectControllers c) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: c.name, decoration: const InputDecoration(labelText: 'Project name'))),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    c.dispose();
                    _projects.removeAt(index);
                  }),
                ),
              ],
            ),
            TextField(controller: c.tech, decoration: const InputDecoration(labelText: 'Tech (comma-separated)')),
            TextField(
              controller: c.description,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: null,
              minLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _educationCard(int index, _EducationControllers c) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: c.degree, decoration: const InputDecoration(labelText: 'Degree'))),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    c.dispose();
                    _education.removeAt(index);
                  }),
                ),
              ],
            ),
            TextField(controller: c.institution, decoration: const InputDecoration(labelText: 'Institution')),
            TextField(controller: c.year, decoration: const InputDecoration(labelText: 'Year')),
          ],
        ),
      ),
    );
  }
}
