import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/job.dart';
import '../models/match_item.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';
import '../widgets/score_ring.dart';
import '../widgets/status_pill.dart';

/// §4.6 Match detail. The full picture of one match before the user commits to
/// tailoring: fit ring + verdict, the role's facts (company, ₹ salary, source),
/// the matched-vs-gap keyword chips (from `matches.strengths` / `matches.gaps`,
/// both already stored), and a footer led by **Apply** — tapping it saves the
/// job to the tracker (silently, no separate confirm gesture — there used to
/// be a standalone "hold to apply as-is" button for this, folded in here
/// since applying already implies tracking it) and opens the in-app browser.
/// Nothing is ever auto-submitted on the actual application.
class MatchDetailScreen extends StatefulWidget {
  const MatchDetailScreen({super.key, required this.match});

  final MatchItem match;

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  final ApiClient _apiClient = ApiClient();
  bool _savedAsIs = false;

  /// Fire-and-forget: called from Apply's onPressed alongside the navigation,
  /// never awaited by it — a failed/slow tracker save shouldn't hold up
  /// opening the browser, which is the part the user actually tapped for.
  Future<void> _saveToTrackerSilently() async {
    if (_savedAsIs) return;
    try {
      await _apiClient.saveToTracker(widget.match.job.id);
      if (!mounted) return;
      setState(() => _savedAsIs = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save to tracker: $e')));
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
          _footer(job),
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

  Widget _footer(Job job) {
    final jobId = job.id;
    final jobTitle = job.title;
    final hasUrl = job.redirectUrl != null && job.redirectUrl!.isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tailor + cover letter are the prep actions, side by side above
            // Apply — the actual "go do this" action, which gets the bottom,
            // full-width, primary slot instead of sharing a row.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/tailor', extra: TailorArgs(jobId: jobId, jobTitle: jobTitle)),
                    icon: AppIcon(AppIconName.fileText, size: 18, color: context.c.accent),
                    label: const Text('Tailor résumé'),
                  ),
                ),
                const SizedBox(width: AppSpacing.space2),
                // Career-ops integration Brick 2 (ADR-056): independent of
                // tailoring — a user may want a cover letter without
                // re-tailoring the résumé, or vice versa.
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/cover-letter', extra: CoverLetterArgs(jobId: jobId, jobTitle: jobTitle)),
                    icon: AppIcon(AppIconName.mail, size: 18, color: context.c.accent),
                    label: const Text('Cover letter'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.space2),
            // Smart AI Fill (career-ops integration): the bottom, primary
            // action. Tapping it saves to the tracker AND opens the in-app
            // browser in one action (there used to be a separate "hold to
            // apply as-is" button for the tracker-save half of this).
            ElevatedButton.icon(
              onPressed: hasUrl
                  ? () {
                      unawaited(_saveToTrackerSilently());
                      context.push(
                        '/form-webview',
                        extra: FormWebViewArgs(browseUrl: job.redirectUrl, formTitle: jobTitle, jobId: jobId, jobTitle: jobTitle),
                      );
                    }
                  : null,
              icon: AppIcon(AppIconName.externalLink, size: 18, color: context.onAccent),
              label: Text(hasUrl ? 'Apply' : 'No posting link available'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ChipTone { match, gap }
