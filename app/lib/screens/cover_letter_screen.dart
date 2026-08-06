import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/cover_letter.dart';
import '../services/api_client.dart';
import '../services/haptic_service.dart';
import '../services/task_center.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/background_task_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// Career-ops integration Brick 2 (docs/21-career-ops-integration-plan.md
/// §1.1, DECISIONS.md ADR-056): generate → guardrail-review → approve →
/// share PDF, all in one screen. Simpler than [ResumeDiffScreen]'s
/// generate/diff/preview split — a cover letter has no bullet-selection
/// step and no separate "compile into a résumé layout" step, so there's
/// nothing a second screen would add.
///
/// Guardrail-flagged paragraphs (Golden Rule 4) default to EXCLUDED from
/// the compiled letter rather than falling back to alternate text — unlike
/// a résumé bullet, a cover letter paragraph has no "original" to revert
/// to (see services/cover_letter_pdf.py::_accepted's docstring).
class CoverLetterScreen extends ConsumerStatefulWidget {
  const CoverLetterScreen({super.key, required this.jobId, required this.jobTitle});

  final String jobId;
  final String jobTitle;

  @override
  ConsumerState<CoverLetterScreen> createState() => _CoverLetterScreenState();
}

class _CoverLetterScreenState extends ConsumerState<CoverLetterScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _errorMessage;
  CoverLetter? _letter;
  List<bool> _accepted = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onTaskChanged(TrackedTask? task) {
    if (!mounted) return;
    if (task?.status == TrackedTaskStatus.done) {
      _fetchExisting();
    } else if (task?.status == TrackedTaskStatus.failed) {
      setState(() {
        _errorMessage = task?.error ?? 'Cover letter drafting failed';
        _isLoading = false;
      });
    }
  }

  void _adopt(CoverLetter letter) {
    _letter = letter;
    _accepted = letter.paragraphs.map((p) => p.accepted ?? p.guardrailPass).toList();
    _isLoading = false;
  }

  Future<void> _fetchExisting() async {
    try {
      final letter = await _apiClient.fetchCoverLetter(widget.jobId);
      if (!mounted || letter == null) return;
      setState(() => _adopt(letter));
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
      final existing = await _apiClient.fetchCoverLetter(widget.jobId);
      if (existing != null) {
        setState(() => _adopt(existing));
        return;
      }
      if (mounted) {
        await showBackgroundTaskDialog(
          context,
          'Drafting your cover letter',
          'Picking 2-3 of your strongest achievements for ${widget.jobTitle} and '
              'verifying every claim against your real resume. This runs in the '
              'background and usually takes under a minute.',
        );
      }
      await ref
          .read(taskCenterProvider.notifier)
          .start(TaskKind.coverLetter, () => _apiClient.generateCoverLetter(widget.jobId), id: widget.jobId);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _approveAndShare() async {
    final letter = _letter;
    if (letter == null) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
    HapticService.instance.light();
    setState(() => _isSubmitting = true);
    try {
      await _apiClient.approveCoverLetter(letter.id, accepted: _accepted);
      final bytes = await _apiClient.downloadCoverLetterPdf(letter.id);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/cover-letter.pdf');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        subject: 'Cover letter — ${widget.jobTitle}',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create cover letter PDF: $e')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(trackedTaskProvider((kind: TaskKind.coverLetter, id: widget.jobId)), (_, next) => _onTaskChanged(next));
    return Scaffold(
      appBar: const PageHeader(title: 'Cover letter', showBack: true),
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
              'Drafting a cover letter for ${widget.jobTitle}…',
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
          title: 'Could not draft cover letter',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final letter = _letter!;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            children: [
              _statusBanner(letter),
              const SizedBox(height: AppSpacing.space3),
              for (var i = 0; i < letter.paragraphs.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.space3),
                _paragraphCard(letter, i),
              ],
            ],
          ),
        ),
        _footer(),
      ],
    );
  }

  Widget _statusBanner(CoverLetter letter) {
    if (letter.guardrailFlags > 0) {
      return AppBanner(
        tone: BannerTone.warning,
        title: '${letter.guardrailFlags} paragraph${letter.guardrailFlags == 1 ? '' : 's'} flagged',
        message: 'Highlighted paragraphs referenced a claim we couldn’t trace back to your resume — excluded by default.',
      );
    }
    return const AppBanner(
      tone: BannerTone.info,
      title: 'Every claim verified',
      message: 'Each paragraph traced back to your resume — review the draft below, then share the PDF.',
    );
  }

  Widget _paragraphCard(CoverLetter letter, int i) {
    final p = letter.paragraphs[i];
    final included = _accepted[i];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: p.guardrailPass ? context.c.border : context.c.critical.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            p.role.toUpperCase(),
            style: AppTypography.label.copyWith(color: context.c.inkFaint),
          ),
          const SizedBox(height: AppSpacing.space2),
          Text(
            p.text,
            style: AppTypography.body.copyWith(
              color: included ? context.c.ink : context.c.inkFaint,
              decoration: included ? null : TextDecoration.lineThrough,
            ),
          ),
          if (p.flaggedAtoms.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space2),
            Wrap(
              spacing: AppSpacing.space2,
              runSpacing: AppSpacing.space2,
              children: [
                for (final a in p.flaggedAtoms)
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
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => setState(() => _accepted[i] = !included),
              style: OutlinedButton.styleFrom(
                backgroundColor: included ? context.c.accentSoft : null,
                side: BorderSide(color: included ? context.c.accent : context.c.border),
              ),
              child: Text(included ? 'Included ✓' : 'Excluded — tap to include'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: ElevatedButton(
          onPressed: _isSubmitting ? null : _approveAndShare,
          child: Text(_isSubmitting ? 'Preparing…' : 'Approve & share PDF'),
        ),
      ),
    );
  }
}
