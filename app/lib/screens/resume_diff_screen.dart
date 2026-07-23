import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Brick 6 → frontend rebuild Phase 7 (Track B, ADR-034): the tailored resume
/// is now a SECTION-LEVEL review, not just a bullet-by-bullet diff.
///
/// - Bullets the deterministic selection KEPT (`selected == true`) show as a
///   diff against the original, with per-bullet keep/use toggles, the R1 atom
///   flags made visible (which exact fact couldn't be traced), and the R3 prose
///   advice shown as non-blocking hints.
/// - Bullets the selection TRIMMED (`selected == false`) live in a collapsible
///   "Trimmed for this job" list, each restorable with one tap — restoring is
///   just accepting it back (ADR-034: no extra endpoint).
///
/// Guardrail-flagged bullets (ADR-004/033 — untraceable claims) are always
/// visible and default to keep-original. This screen never submits anything on
/// its own (golden rule: no auto-submitting anywhere).
class ResumeDiffScreen extends ConsumerStatefulWidget {
  const ResumeDiffScreen({super.key, required this.jobId, required this.jobTitle});

  final String jobId;
  final String jobTitle;

  @override
  ConsumerState<ResumeDiffScreen> createState() => _ResumeDiffScreenState();
}

class _ResumeDiffScreenState extends ConsumerState<ResumeDiffScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  bool _isGenerating = false;
  bool _showTrimmed = false;
  String? _errorMessage;
  TailoredResume? _resume;

  // One entry per stored bullet (selected + trimmed), aligned to
  // `resume.bullets` order — that's the contract PATCH /tailor/{id}/approve
  // expects. Trimmed bullets start `false` (not on the resume) until restored.
  List<bool> _accepted = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onTailorChanged(TrackedTask? task) {
    if (!mounted) return;
    if (task?.status == TrackedTaskStatus.done) {
      _fetchExisting(); // the tailored row is stored server-side — read it back
    } else if (task?.status == TrackedTaskStatus.failed) {
      setState(() {
        _errorMessage = task?.error ?? 'Tailoring failed';
        _isLoading = false;
      });
    }
  }

  void _adopt(TailoredResume resume) {
    _resume = resume;
    _accepted = resume.bullets.map((b) => b.accepted ?? (b.selected && b.guardrailPass)).toList();
    _isLoading = false;
  }

  Future<void> _fetchExisting() async {
    try {
      final resume = await _apiClient.fetchTailoredResume(widget.jobId);
      if (!mounted || resume == null) return;
      setState(() => _adopt(resume));
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
        setState(() => _adopt(existing));
        return;
      }
      // No cached tailoring for this job — kick off the background task. The
      // skeleton stays up while we wait; the app remains navigable and
      // _onTailorChanged picks up the result.
      if (mounted) {
        await showBackgroundTaskDialog(
          context,
          'Tailoring your resume',
          'Choosing which of your bullets matter most for ${widget.jobTitle}, '
              'rewriting them, and verifying every claim against your real '
              'resume. This runs in the background and usually takes under a minute.',
        );
      }
      await ref
          .read(taskCenterProvider.notifier)
          .start(TaskKind.tailor, () => _apiClient.tailorResume(widget.jobId), id: widget.jobId);
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
      await context.push('/tailor/preview', extra: TailorArgs(jobId: widget.jobId, jobTitle: widget.jobTitle));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate resume: $e')));
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(trackedTaskProvider((kind: TaskKind.tailor, id: widget.jobId)),
        (_, next) => _onTailorChanged(next));
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
              'Choosing and rewriting your best bullets for ${widget.jobTitle}…',
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
    // Indices into the full stored array, split by selection. We iterate the
    // full array so `_accepted` positions stay correct.
    final selected = <int>[];
    final trimmed = <int>[];
    for (var i = 0; i < resume.bullets.length; i++) {
      (resume.bullets[i].selected ? selected : trimmed).add(i);
    }
    // R3 prose findings are keyed by position within the SELECTED list.
    final proseByPos = <int, List<ProseFinding>>{};
    for (final f in resume.analysis?.proseFindings ?? const <ProseFinding>[]) {
      proseByPos.putIfAbsent(f.bulletIndex, () => []).add(f);
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            children: [
              _headerBanners(resume),
              const SizedBox(height: AppSpacing.space3),
              for (var pos = 0; pos < selected.length; pos++) ...[
                if (pos > 0) const SizedBox(height: AppSpacing.space3),
                _selectedBullet(resume, selected[pos], proseByPos[pos] ?? const []),
              ],
              if (trimmed.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.space4),
                _trimmedSection(resume, trimmed),
              ],
            ],
          ),
        ),
        _footer(resume, selected),
      ],
    );
  }

  Widget _selectedBullet(TailoredResume resume, int i, List<ProseFinding> prose) {
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
        if (bullet.flaggedAtoms.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.space2),
          _atomFlags(bullet.flaggedAtoms),
        ],
        for (final f in prose) ...[
          const SizedBox(height: AppSpacing.space2),
          _proseHint(f),
        ],
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
  }

  // R1: name the exact untraceable facts so a flag reads as honest, not opaque.
  Widget _atomFlags(List<FlaggedAtom> atoms) {
    return Wrap(
      spacing: AppSpacing.space2,
      runSpacing: AppSpacing.space2,
      children: [
        for (final a in atoms)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.criticalSoft,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: AppColors.critical600),
            ),
            child: Text(
              'Not in your resume: ${a.text}',
              style: AppTypography.caption.copyWith(color: AppColors.criticalText),
            ),
          ),
      ],
    );
  }

  // R3: advisory only — a quiet hint row, never a blocker.
  Widget _proseHint(ProseFinding f) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppIcon(AppIconName.info, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.space2),
        Expanded(
          child: Text(
            f.message,
            style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  // ADR-034: the "Trimmed" list — bullets deterministic selection cut for this
  // job, disclosed and one-tap restorable (restore = accept it back).
  Widget _trimmedSection(TailoredResume resume, List<int> trimmed) {
    final restoredCount = trimmed.where((i) => _accepted[i]).length;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.neutralSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _showTrimmed = !_showTrimmed),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.space3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Trimmed for this job (${trimmed.length})'
                      '${restoredCount > 0 ? ' · $restoredCount restored' : ''}',
                      style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  AppIcon(_showTrimmed ? AppIconName.chevronDown : AppIconName.chevronRight, size: 18),
                ],
              ),
            ),
          ),
          if (_showTrimmed)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.space3, 0, AppSpacing.space3, AppSpacing.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'These were set aside to keep the resume to one focused page. '
                    'Restore any that still matter.',
                    style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                  ),
                  for (final i in trimmed) ...[
                    const SizedBox(height: AppSpacing.space3),
                    _trimmedBullet(resume, i),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _trimmedBullet(TailoredResume resume, int i) {
    final bullet = resume.bullets[i];
    final restored = _accepted[i];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: restored ? AppColors.brand500 : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(bullet.original, style: AppTypography.body),
          if ((bullet.trimReason ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space1),
            Text(bullet.trimReason!, style: AppTypography.caption.copyWith(color: AppColors.textSecondary)),
          ],
          const SizedBox(height: AppSpacing.space2),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => setState(() => _accepted[i] = !restored),
              style: OutlinedButton.styleFrom(
                backgroundColor: restored ? AppColors.brandSoft : null,
                side: BorderSide(color: restored ? AppColors.brand500 : AppColors.border),
              ),
              child: Text(restored ? 'Restored ✓' : 'Restore'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(TailoredResume resume, List<int> selected) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: Row(
          children: [
            // See profile_body.dart's Edit button for why this is pinned to a
            // tight SizedBox instead of sitting bare in the Row (Flutter layout
            // bug on this SDK: a non-flex OutlinedButton throws "BoxConstraints
            // forces an infinite width" on first layout and blanks the screen).
            SizedBox(
              width: 108,
              height: 48,
              child: OutlinedButton(
                onPressed: _isGenerating
                    ? null
                    : () => setState(() {
                          for (final i in selected) {
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
    );
  }

  // ADR-019/034: the header stacks context banners — the JD-analysis, the
  // guardrail status, a summary-fell-back note, and the gap disclosure. Gaps are
  // JD requirements the resume can't honestly claim; showing them is the
  // framework's non-negotiable honesty step — they're never written onto it.
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
              ? 'Read as a $role role — your most relevant bullets selected and reordered to lead with what this job asks for.'
              : 'Your most relevant bullets selected and reordered to lead with what this job asks for.',
        ),
      );
    }

    banners.add(_statusBanner(resume));

    if (analysis != null && !analysis.summaryGuardrailPass) {
      banners.add(
        const AppBanner(
          tone: BannerTone.warning,
          title: 'Summary kept as your own',
          message: 'The reframed summary introduced a claim we couldn’t trace, so your original headline is used instead.',
        ),
      );
    }

    if (resume.gaps.isNotEmpty) {
      banners.add(
        AppBanner(
          tone: BannerTone.warning,
          title: 'Requirements you may not fully meet',
          message: '${resume.gaps.join(', ')}. These are not claimed on your resume — flag them honestly if asked.',
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
