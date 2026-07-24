import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/match_item.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/hold_button.dart';
import '../widgets/page_header.dart';
import '../widgets/score_ring.dart';
import '../widgets/status_pill.dart';

/// §4.6 Match detail. The full picture of one match before the user commits to
/// tailoring: fit ring + verdict, the role's facts (company, ₹ salary, source),
/// the matched-vs-gap keyword chips (from `matches.strengths` / `matches.gaps`,
/// both already stored), and a footer with the two honest next steps —
/// **tailor the résumé for this JD**, or **hold to apply as-is** (nothing is
/// auto-submitted; "apply as-is" only saves the untailored job to the tracker).
class MatchDetailScreen extends StatefulWidget {
  const MatchDetailScreen({super.key, required this.match});

  final MatchItem match;

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  final ApiClient _apiClient = ApiClient();
  bool _savedAsIs = false;

  Future<void> _applyAsIs() async {
    try {
      await _apiClient.saveToTracker(widget.match.job.id);
      if (!mounted) return;
      setState(() => _savedAsIs = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    final job = m.job;
    return Scaffold(
      appBar: const PageHeader(title: 'Match', showBack: true),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadX),
              children: [
                _headerCard(m),
                if (_savedAsIs) ...[
                  const SizedBox(height: AppSpacing.space3),
                  const AppBanner(
                    tone: BannerTone.success,
                    title: 'Saved to your tracker',
                    message: 'Added as “applied as-is”. Tailor it any time from the tracker.',
                  ),
                ],
                const SizedBox(height: AppSpacing.space3),
                const AppBanner(
                  tone: BannerTone.info,
                  title: 'Not tailored yet',
                  message: 'This is your stored résumé’s fit. Tailoring rewrites your bullets toward this exact JD.',
                ),
                if (m.strengths.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.space4),
                  _chipSection('Why it fits', m.strengths, _ChipTone.match),
                ],
                if (m.gaps.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.space4),
                  _chipSection('Gaps to be aware of', m.gaps, _ChipTone.gap),
                ],
              ],
            ),
          ),
          _footer(job.id, job.title),
        ],
      ),
    );
  }

  Widget _headerCard(MatchItem m) {
    final job = m.job;
    final meta = <String>[
      if (job.company != null) job.company!,
      if (job.location != null) job.location!,
      if (job.salaryLabel != null) job.salaryLabel!,
      job.source,
    ];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: AppRadius.lgRadius,
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoreRing(score: m.fitScore, size: 64),
              const SizedBox(width: AppSpacing.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.title, style: AppTypography.title.copyWith(fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(meta.join(' · '),
                        style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
                    const SizedBox(height: AppSpacing.space2),
                    StatusPill(context: PillContext.verdict, value: m.verdict),
                  ],
                ),
              ),
            ],
          ),
          if (m.oneLineReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space3),
            Text(m.oneLineReason, style: AppTypography.body),
          ],
        ],
      ),
    );
  }

  Widget _chipSection(String label, List<String> items, _ChipTone tone) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTypography.label.copyWith(color: context.c.inkFaint)),
        const SizedBox(height: AppSpacing.space2),
        Wrap(
          spacing: AppSpacing.space2,
          runSpacing: AppSpacing.space2,
          children: [for (final it in items) _chip(it, tone)],
        ),
      ],
    );
  }

  Widget _chip(String label, _ChipTone tone) {
    final (bg, fg, border) = switch (tone) {
      _ChipTone.match => (context.c.success.withValues(alpha: 0.12), context.c.success, context.c.success.withValues(alpha: 0.30)),
      _ChipTone.gap => (context.c.warning.withValues(alpha: 0.12), context.c.warning, context.c.warning.withValues(alpha: 0.30)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.pill), border: Border.all(color: border)),
      child: Text(label, style: AppTypography.caption.copyWith(color: fg)),
    );
  }

  Widget _footer(String jobId, String jobTitle) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: () => context.push('/tailor', extra: TailorArgs(jobId: jobId, jobTitle: jobTitle)),
              icon: AppIcon(AppIconName.fileText, size: 18, color: context.onAccent),
              label: const Text('Tailor résumé for this JD'),
            ),
            const SizedBox(height: AppSpacing.space2),
            HoldButton(
              idleLabel: _savedAsIs ? 'Applied as-is ✓' : 'Hold to apply as-is',
              activeLabel: 'Keep holding…',
              onComplete: () {
                if (!_savedAsIs) _applyAsIs();
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _ChipTone { match, gap }
