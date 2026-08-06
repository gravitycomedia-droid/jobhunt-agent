import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/interview_prep.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

const Map<String, String> _kCategoryLabels = {
  'behavioral': 'Behavioral',
  'technical': 'Technical',
  'gap': 'Probes a gap',
  'company_fit': 'Company fit',
};

/// Career-ops integration Brick 4 (docs/21-career-ops-integration-plan.md
/// §1.2, DECISIONS.md ADR-058): generates a per-job interview pack —
/// likely questions plus STAR-format suggested answers, grounded only in
/// the candidate's real profile (v1: no web search). Unlike
/// [CoverLetterScreen], nothing here is stored server-side (a pack is
/// disposable, regenerated fresh each visit) — so "Save as story" is the
/// one explicit action that survives, writing into the persistent story
/// bank (interview_story.dart) reachable via the app bar action.
class InterviewPrepScreen extends StatefulWidget {
  const InterviewPrepScreen({super.key, required this.applicationId, required this.jobTitle});

  final String applicationId;
  final String jobTitle;

  @override
  State<InterviewPrepScreen> createState() => _InterviewPrepScreenState();
}

class _InterviewPrepScreenState extends State<InterviewPrepScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  InterviewPack? _pack;
  final Set<int> _savedIndices = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _savedIndices.clear();
    });
    try {
      final pack = await _apiClient.generateInterviewPack(widget.applicationId);
      if (!mounted) return;
      setState(() {
        _pack = pack;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _saveAsStory(int index, InterviewQuestion q) async {
    try {
      await _apiClient.createInterviewStory(
        situation: q.situation,
        task: q.task,
        action: q.action,
        result: q.result,
        sourceJobId: _pack?.jobId,
      );
      if (!mounted) return;
      setState(() => _savedIndices.add(index));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to your story bank')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageHeader(
        title: 'Interview prep',
        showBack: true,
        actions: [
          HeaderActionButton(
            icon: AppIconName.book,
            tooltip: 'Story bank',
            onPressed: () => context.push('/story-bank'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space3, AppSpacing.screenPadX, 0),
            child: Text(
              'Preparing questions for ${widget.jobTitle}…',
              style: AppTypography.caption.copyWith(color: context.c.inkSoft),
            ),
          ),
          const Expanded(child: Center(child: AppLoader())),
        ],
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not prepare interview pack',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final pack = _pack!;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        const AppBanner(
          tone: BannerTone.info,
          title: 'v1: no web search',
          message: 'Questions are grounded in this job\'s posting and your real profile. Questions labeled "inferred" are reasonable for this type of role, but not literally stated in the JD.',
        ),
        const SizedBox(height: AppSpacing.space3),
        for (var i = 0; i < pack.questions.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.space3),
          _questionCard(i, pack.questions[i]),
        ],
        const SizedBox(height: AppSpacing.space3),
        Align(
          alignment: Alignment.center,
          child: TextButton(onPressed: _load, child: const Text('Regenerate pack')),
        ),
      ],
    );
  }

  Widget _questionCard(int index, InterviewQuestion q) {
    final alreadySaved = _savedIndices.contains(index);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: q.guardrailPass ? context.c.border : context.c.critical.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.space2,
            runSpacing: 4,
            children: [
              _tag(_kCategoryLabels[q.category] ?? q.category, context.c.info),
              if (q.inferred) _tag('Inferred', context.c.warning),
              if (!q.guardrailPass) _tag('Guardrail fail', context.c.critical),
            ],
          ),
          const SizedBox(height: AppSpacing.space2),
          Text(q.question, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.space2),
          _starField('Situation', q.situation),
          _starField('Task', q.task),
          _starField('Action', q.action),
          if (q.result.isNotEmpty) _starField('Result', q.result),
          if (q.flaggedAtoms.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space2),
            Wrap(
              spacing: AppSpacing.space2,
              runSpacing: AppSpacing.space2,
              children: [
                for (final a in q.flaggedAtoms)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.c.critical.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(color: context.c.critical),
                    ),
                    child: Text(
                      'Not in your resume: ${a.text}',
                      style: AppTypography.caption.copyWith(color: context.c.critical),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.space2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: alreadySaved ? null : () => _saveAsStory(index, q),
              child: Text(alreadySaved ? 'Saved ✓' : 'Save as story'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _starField(String label, String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: AppTypography.bodySm.copyWith(color: context.c.ink),
          children: [
            TextSpan(text: '$label: ', style: TextStyle(fontWeight: FontWeight.w700, color: context.c.inkFaint)),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }

  Widget _tag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: AppTypography.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
    );
  }
}
