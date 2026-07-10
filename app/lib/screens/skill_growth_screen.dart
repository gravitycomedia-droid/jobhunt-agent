import 'package:flutter/material.dart';

import '../models/skill_growth_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';

/// Phase 4 (prototype `ui.isSkillGrowth`): skills-to-learn derived from
/// real match gaps, with LLM-suggested courses/project ideas. The
/// prototype shows a fabricated "+12% matches" per skill; this shows a
/// real "N of M matches" frequency instead (computed server-side — see
/// server/services/skill_growth.py) and never a made-up percentage.
class SkillGrowthScreen extends StatefulWidget {
  const SkillGrowthScreen({super.key});

  @override
  State<SkillGrowthScreen> createState() => _SkillGrowthScreenState();
}

class _SkillGrowthScreenState extends State<SkillGrowthScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  List<SkillGrowthItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final items = await _apiClient.fetchSkillGrowth();
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grow your match rate')),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: const [LoadingSkeleton(variant: SkeletonVariant.card)],
      );
    }

    if (_errorMessage != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load skill growth',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        children: const [
          EmptyState(
            icon: AppIconName.trendingUp,
            title: 'Nothing to learn from yet',
            message: 'Once the agent has scored some matches, skill gaps show up here.',
          ),
        ],
      );
    }

    final courses = [for (final item in _items) for (final c in item.courses) (item.skill, c)];
    final projects = [for (final item in _items) for (final p in item.projects) (item.skill, p)];

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        Text(
          'Skills, courses and projects the agent thinks would move the needle most.',
          style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.space5),
        Text('SKILLS TO LEARN', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
        const SizedBox(height: AppSpacing.space2),
        for (final item in _items) ...[
          _skillCard(item),
          const SizedBox(height: AppSpacing.space2),
        ],
        if (courses.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.space3),
          Text('RECOMMENDED COURSES', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.space2),
          for (final (skill, course) in courses) ...[
            _courseRow(skill, course),
            const SizedBox(height: AppSpacing.space2),
          ],
        ],
        if (projects.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.space3),
          Text('PROJECT IDEAS', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.space2),
          for (final (_, project) in projects) ...[
            _projectCard(project),
            const SizedBox(height: AppSpacing.space2),
          ],
        ],
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: child,
    );
  }

  Widget _skillCard(SkillGrowthItem item) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(item.skill, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700))),
              const SizedBox(width: AppSpacing.space2),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.successSoft,
                  border: Border.all(color: AppColors.successBorder),
                  borderRadius: AppRadius.pillRadius,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  child: Text(
                    item.frequencyLabel,
                    style: AppTypography.caption.copyWith(color: AppColors.successText, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(item.reason, style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _courseRow(String skill, SkillCourse course) {
    return _card(
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
            child: const AppIcon(AppIconName.fileText, size: 18, color: AppColors.brand600),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(course.title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${course.provider} · ${course.duration}', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectCard(SkillProject project) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(project.title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(project.impact, style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
