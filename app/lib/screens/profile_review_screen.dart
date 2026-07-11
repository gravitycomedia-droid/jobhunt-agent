import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

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

  /// Onboarding (frontend rebuild Phase 1): called instead of popping when
  /// provided, so the onboarding chain can continue to Target Roles. Null
  /// (the default) when reached from the Profile tab, where popping back
  /// to the caller is correct.
  final VoidCallback? onSaved;

  /// Phase 3B: true inside [OnboardingFlow]'s step machine — the flow
  /// provides the progress chrome and there's no route to pop, so hide
  /// this screen's own header/back.
  final bool embedded;

  const ProfileReviewScreen({super.key, required this.profile, this.onSaved, this.embedded = false});

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
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved.')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : const PageHeader(title: 'Review Profile', showBack: true),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          _sectionLabel('Basics'),
          AppFormField(label: 'Name', controller: _name, required: true),
          const SizedBox(height: AppSpacing.space3),
          AppFormField(label: 'Headline', controller: _headline),
          const SizedBox(height: AppSpacing.space3),
          AppFormField(label: 'Skills', hint: 'Comma-separated', controller: _skills, multiline: true, rows: 2),
          const SizedBox(height: AppSpacing.space6),
          _sectionLabel('Experience'),
          ..._experience.asMap().entries.map((entry) => _experienceCard(entry.key, entry.value)),
          _addButton('Add experience', () => setState(() => _experience.add(
                _ExperienceControllers.fromItem(
                  ExperienceItem(role: '', company: '', duration: '', bullets: []),
                ),
              ))),
          const SizedBox(height: AppSpacing.space6),
          _sectionLabel('Projects'),
          ..._projects.asMap().entries.map((entry) => _projectCard(entry.key, entry.value)),
          _addButton(
            'Add project',
            () => setState(() => _projects.add(_ProjectControllers.fromItem(ProjectItem(name: '', tech: [], description: '')))),
          ),
          const SizedBox(height: AppSpacing.space6),
          _sectionLabel('Education'),
          ..._education.asMap().entries.map((entry) => _educationCard(entry.key, entry.value)),
          _addButton(
            'Add education',
            () => setState(() => _education.add(
                  _EducationControllers.fromItem(EducationItem(degree: '', institution: '', year: '')),
                )),
          ),
          const SizedBox(height: AppSpacing.space6),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.space3),
              child: Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: AppColors.criticalText)),
            ),
          ElevatedButton(
            onPressed: _isSaving ? null : _confirm,
            child: _isSaving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textOnBrand),
                  )
                : const Text('Confirm'),
          ),
          const SizedBox(height: AppSpacing.space8),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.space2),
        child: Text(text, style: AppTypography.headingSm),
      );

  Widget _addButton(String label, VoidCallback onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const AppIcon(AppIconName.plus, size: 16, color: AppColors.brand),
      label: Text(label),
    );
  }

  Widget _itemCard({required List<Widget> children, required VoidCallback onDelete}) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.space3),
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: onDelete,
              borderRadius: AppRadius.smRadius,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: AppIcon(AppIconName.x, size: 16, color: AppColors.textTertiary),
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _experienceCard(int index, _ExperienceControllers c) {
    return _itemCard(
      onDelete: () => setState(() {
        c.dispose();
        _experience.removeAt(index);
      }),
      children: [
        AppFormField(label: 'Role', controller: c.role),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Company', controller: c.company),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Duration', controller: c.duration),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Bullets', hint: 'One per line', controller: c.bullets, multiline: true, rows: 3),
      ],
    );
  }

  Widget _projectCard(int index, _ProjectControllers c) {
    return _itemCard(
      onDelete: () => setState(() {
        c.dispose();
        _projects.removeAt(index);
      }),
      children: [
        AppFormField(label: 'Project name', controller: c.name),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Tech', hint: 'Comma-separated', controller: c.tech),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Description', controller: c.description, multiline: true, rows: 3),
      ],
    );
  }

  Widget _educationCard(int index, _EducationControllers c) {
    return _itemCard(
      onDelete: () => setState(() {
        c.dispose();
        _education.removeAt(index);
      }),
      children: [
        AppFormField(label: 'Degree', controller: c.degree),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Institution', controller: c.institution),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(label: 'Year', controller: c.year),
      ],
    );
  }
}
