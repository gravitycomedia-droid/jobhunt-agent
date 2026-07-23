import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/tailored_resume.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/task_center.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/background_task_dialog.dart';
import '../widgets/diff_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';
import '../widgets/page_skeletons.dart';

/// Brick 6, extended in the frontend rebuild's Phase 2: shows a tailored
/// resume as a bullet-by-bullet diff against the stored original, with
/// guardrail-failed bullets (ADR-004 — untraceable claims the LLM
/// invented) highlighted critical rather than silently accepted. Each
/// bullet now has its own keep-original/use-tailored toggle (prototype
/// `ui.isTailoring`) instead of one global approve — "Generate tailored
/// resume" persists those per-bullet choices (PATCH /tailor/{id}/approve)
/// and hands off to [ResumePreviewScreen]. This screen never submits
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

  // ADR-011: tailoring is a 202-style background task now — TaskCenter
  // owns the poll loop, so tailoring keeps running (and completes with a
  // toast) even if the user backs out of this screen mid-generation.
  // Scoped by jobId (not just TaskKind.tailor) so tailoring one job doesn't
  // silently block/collide with tailoring another — see TaskCenter.start's
  // "one active task per kind+id" contract. Without this, opening job B's
  // diff screen while job A's tailor task was still running would no-op the
  // start call for B entirely, leaving B on the loading skeleton (or, worse,
  // eventually resolving with A's completion event and showing A's diff).
  ValueNotifier<TrackedTask?> get _tailorTask => TaskCenter.instance.notifierFor(TaskKind.tailor, id: widget.jobId);

  @override
  void initState() {
    super.initState();
    _tailorTask.addListener(_onTailorChanged);
    _load();
  }

  @override
  void dispose() {
    _tailorTask.removeListener(_onTailorChanged);
    super.dispose();
  }

  void _onTailorChanged() {
    if (!mounted) return;
    final task = _tailorTask.value;
    if (task?.status == TrackedTaskStatus.done) {
      _fetchExisting(); // the tailored row is stored server-side — read it back
    } else if (task?.status == TrackedTaskStatus.failed) {
      setState(() {
        _errorMessage = task?.error ?? 'Tailoring failed';
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchExisting() async {
    try {
      final resume = await _apiClient.fetchTailoredResume(widget.jobId);
      if (!mounted || resume == null) return;
      setState(() {
        _resume = resume;
        _accepted = resume.bullets.map((b) => b.accepted ?? b.guardrailPass).toList();
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

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final existing = await _apiClient.fetchTailoredResume(widget.jobId);
      if (existing != null) {
        setState(() {
          _resume = existing;
          _accepted = existing.bullets.map((b) => b.accepted ?? b.guardrailPass).toList();
          _isLoading = false;
        });
        return;
      }
      // No cached tailoring for this job — kick off the background task.
      // The skeleton stays up while we wait, but the screen (and the whole
      // app) remains navigable; _onTailorChanged picks up the result.
      if (mounted) {
        await showBackgroundTaskDialog(
          context,
          'Tailoring your resume',
          'Rewriting your experience bullets toward ${widget.jobTitle} and '
              'verifying every claim against your real resume. This runs in '
              'the background and usually takes under a minute.',
        );
      }
      await TaskCenter.instance.start(TaskKind.tailor, () => _apiClient.tailorResume(widget.jobId), id: widget.jobId);
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
      // The approve PATCH is a fast row update (~1s) — the tailoring LLM
      // work already happened. No fake "compiling" pause (Phase 2): go
      // straight to the compiled preview.
      await _apiClient.approveTailoredResume(resume.id, accepted: _accepted);
      if (!mounted) return;
      // Just push — ResumePreviewScreen's own back button already pops
      // itself. Popping again here on return raced that pop's still-running
      // transition and threw a RenderBox-not-laid-out assertion.
      await context.push('/tailor/preview',
          extra: TailorArgs(jobId: widget.jobId, jobTitle: widget.jobTitle));
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
      appBar: const PageHeader(title: 'Tailored resume', showBack: true),
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
              itemBuilder: (_, _) => const DiffRowSkeleton(),
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
              if (index == 0) return _headerBanners(resume);
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
                // See profile_body.dart's Edit button for why this is
                // pinned to a tight SizedBox instead of sitting bare in
                // the Row (Flutter layout bug on this SDK: a non-flex
                // OutlinedButton here throws "BoxConstraints forces an
                // infinite width" on first layout and blanks the screen).
                SizedBox(
                  width: 108,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _isGenerating
                        ? null
                        : () => setState(() {
                              for (var i = 0; i < _accepted.length; i++) {
                                if (resume.bullets[i].guardrailPass) _accepted[i] = true;
                              }
                            }),
                    child: const Text('Accept all'),
                  ),
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

  // ADR-019: index-0 header now stacks up to three banners — the JD-analysis
  // context (role type + matched title), the guardrail status, and the gap
  // disclosure. Gaps are JD requirements the resume can't honestly claim;
  // showing them here is the framework's non-negotiable honesty step — they're
  // never written onto the resume.
  Widget _headerBanners(TailoredResume resume) {
    final banners = <Widget>[];

    final analysis = resume.analysis;
    if (analysis != null && (analysis.roleType.isNotEmpty || analysis.jdTitle.isNotEmpty)) {
      final role = analysis.roleType.replaceAll('_', ' ');
      banners.add(
        AppBanner(
          tone: BannerTone.info,
          title: analysis.jdTitle.isNotEmpty ? 'Tailored for “${analysis.jdTitle}”' : 'Tailored resume',
          message: role.isNotEmpty
              ? 'Read as a $role role — bullets and skills reordered to lead with what this job asks for.'
              : 'Bullets and skills reordered to lead with what this job asks for.',
        ),
      );
    }

    banners.add(_statusBanner(resume));

    if (resume.gaps.isNotEmpty) {
      banners.add(
        AppBanner(
          tone: BannerTone.warning,
          title: 'Requirements you may not fully meet',
          message:
              '${resume.gaps.join(', ')}. These are not claimed on your resume — flag them honestly if asked.',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < banners.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.space2),
          banners[i],
        ],
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
