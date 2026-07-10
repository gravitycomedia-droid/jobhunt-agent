import 'package:flutter/material.dart';

import '../models/tailored_resume.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/diff_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import 'resume_generating_screen.dart';

/// Brick 6, extended in the frontend rebuild's Phase 2: shows a tailored
/// resume as a bullet-by-bullet diff against the stored original, with
/// guardrail-failed bullets (ADR-004 — untraceable claims the LLM
/// invented) highlighted critical rather than silently accepted. Each
/// bullet now has its own keep-original/use-tailored toggle (prototype
/// `ui.isTailoring`) instead of one global approve — "Generate tailored
/// resume" persists those per-bullet choices (PATCH /tailor/{id}/approve)
/// and hands off to [ResumeGeneratingScreen]. This screen never submits
/// anything on its own (golden rule: no auto-submitting anywhere).
class ResumeDiffScreen extends StatefulWidget {
  const ResumeDiffScreen({super.key, required this.jobId, required this.jobTitle});

  final String jobId;
  final String jobTitle;

  @override
  State<ResumeDiffScreen> createState() => _ResumeDiffScreenState();
}

class _ResumeDiffScreenState extends State<ResumeDiffScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  bool _isGenerating = false;
  String? _errorMessage;
  TailoredResume? _resume;
  List<bool> _accepted = [];

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
      final existing = await _apiClient.fetchTailoredResume(widget.jobId);
      final resume = existing ?? await _apiClient.tailorResume(widget.jobId);
      setState(() {
        _resume = resume;
        _accepted = resume.bullets.map((b) => b.accepted ?? b.guardrailPass).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _generate() async {
    final resume = _resume;
    if (resume == null) return;
    setState(() => _isGenerating = true);
    try {
      await _apiClient.approveTailoredResume(resume.id, accepted: _accepted);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResumeGeneratingScreen(jobId: widget.jobId, jobTitle: widget.jobTitle),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate resume: $e')));
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tailored resume')),
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
              'Tailoring bullets toward ${widget.jobTitle}…',
              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.screenPadX),
              itemCount: 4,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
              itemBuilder: (_, _) => const LoadingSkeleton(variant: SkeletonVariant.card),
            ),
          ),
        ],
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not tailor resume',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final resume = _resume!;
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            itemCount: resume.bullets.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
            itemBuilder: (context, index) {
              if (index == 0) return _statusBanner(resume);
              final i = index - 1;
              final bullet = resume.bullets[i];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DiffRow(
                    original: bullet.original,
                    tailored: bullet.tailored,
                    guardrailFail: !bullet.guardrailPass,
                    unchanged: !_accepted[i],
                  ),
                  const SizedBox(height: AppSpacing.space2),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() => _accepted[i] = false),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: _accepted[i] ? null : AppColors.neutralSoft,
                            side: BorderSide(color: _accepted[i] ? AppColors.border : AppColors.borderStrong),
                          ),
                          child: const Text('Keep original'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.space2),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: bullet.guardrailPass ? () => setState(() => _accepted[i] = true) : null,
                          style: OutlinedButton.styleFrom(
                            backgroundColor: _accepted[i] ? AppColors.brandSoft : null,
                            side: BorderSide(color: _accepted[i] ? AppColors.brand500 : AppColors.border),
                          ),
                          child: const Text('Use tailored'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: _isGenerating
                      ? null
                      : () => setState(() {
                            for (var i = 0; i < _accepted.length; i++) {
                              if (resume.bullets[i].guardrailPass) _accepted[i] = true;
                            }
                          }),
                  child: const Text('Accept all'),
                ),
                const SizedBox(width: AppSpacing.space3),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isGenerating ? null : _generate,
                    child: Text(_isGenerating ? 'Generating…' : 'Generate tailored resume'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusBanner(TailoredResume resume) {
    if (resume.guardrailFlags > 0) {
      return AppBanner(
        tone: BannerTone.warning,
        title: '${resume.guardrailFlags} bullet${resume.guardrailFlags == 1 ? '' : 's'} flagged',
        message: 'Highlighted bullets could not be traced back to your resume — kept as original by default.',
      );
    }
    return const AppBanner(
      tone: BannerTone.info,
      title: 'All bullets verified',
      message: 'Every tailored bullet traced back to your resume — choose which edits to use below.',
    );
  }
}
