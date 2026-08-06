import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/job.dart';
import '../router/route_args.dart';
import '../services/job_filter.dart' show kJobCategoryLabels;
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// Career-ops integration — Smart AI Fill: the Jobs tab's "tap a job → see
/// the full posting in-app → Apply" flow (job_card.dart's `onPress` used to
/// be unwired; this is its destination). Mirrors [MatchDetailScreen]'s shape
/// for a raw [Job] instead of a scored [MatchItem] — no fit ring/verdict
/// here, just the posting's own facts, surfaced in full so the user can
/// actually understand the JD without leaving the app.
///
/// "Apply" pushes the in-app WebView (form_webview_screen.dart) in plain
/// browse mode on the job's own posting URL — nothing is parsed or filled
/// until the user explicitly taps "Smart AI Fill" once they've navigated to
/// the real application page, same posture ADR-053 already established for
/// the sign-in-gated Google Forms path.
class JobDetailScreen extends StatelessWidget {
  const JobDetailScreen({super.key, required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Job details', showBack: true),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadX),
              children: [
                _headerCard(context),
                const SizedBox(height: AppSpacing.space3),
                _factsWrap(context),
                if (_legitimacySignals.isNotEmpty || _contractorNote != null) ...[
                  const SizedBox(height: AppSpacing.space4),
                  _legitimacySection(context),
                ],
                if (_description != null) ...[
                  const SizedBox(height: AppSpacing.space4),
                  Text('DESCRIPTION', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
                  const SizedBox(height: AppSpacing.space2),
                  Text(_description!, style: AppTypography.body.copyWith(color: context.c.ink)),
                ],
              ],
            ),
          ),
          _footer(context),
        ],
      ),
    );
  }

  String? get _description {
    final d = job.raw['description'] as String?;
    return (d == null || d.trim().isEmpty) ? null : d.trim();
  }

  /// Defensive read, not a promise the field exists: no current ingestion
  /// source (Adzuna/JSearch/Greenhouse/Lever/Unstop/Internshala/Naukri/
  /// Instahyre) populates a company-logo column today, so this is null for
  /// every job right now — [_CompanyLogo] falls back to the initial tile in
  /// that case, same as [JobCard]'s own logo slot always has. Reading a few
  /// plausible key names here means a job DOES pick one up automatically the
  /// day a source starts sending one, with no client change required.
  String? get _logoUrl {
    for (final key in const ['logo_url', 'company_logo', 'company_logo_url', 'logo']) {
      final v = job.raw[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  List<dynamic> get _legitimacySignals => (job.legitimacySignals?['signals'] as List?) ?? const [];
  String? get _contractorNote {
    final n = job.legitimacySignals?['contractor_language_note'] as String?;
    return (n == null || n.trim().isEmpty) ? null : n.trim();
  }

  Widget _headerCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: AppRadius.lgRadius,
        border: Border.all(color: context.c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CompanyLogo(company: job.company ?? job.title, logoUrl: _logoUrl),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.title, style: AppTypography.title.copyWith(fontSize: 17, fontWeight: FontWeight.w800, color: context.c.ink)),
                const SizedBox(height: 4),
                Text(job.company ?? 'Unknown company', style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
                const SizedBox(height: AppSpacing.space2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SourceBadge(source: job.source),
                    const SizedBox(width: 6),
                    Text(job.source, style: AppTypography.caption.copyWith(color: context.c.inkFaint)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Every fact the raw job JSON actually carries, one chip each — location,
  /// salary, work type, discipline, posted date. Nothing here is invented:
  /// a field that's null on this posting just doesn't get a chip.
  Widget _factsWrap(BuildContext context) {
    final chips = <Widget>[
      if (job.location != null) _factChip(context, AppIconName.mapPin, job.location!),
      if (job.salaryLabel != null) _factChip(context, null, job.salaryLabel!, mono: true),
      if (job.workType != null) _factChip(context, null, _workTypeLabel(job.workType!)),
      if (job.category != null) _factChip(context, null, kJobCategoryLabels[job.category] ?? job.category!),
      if (job.postedAtLabel != null) _factChip(context, AppIconName.clock, job.postedAtLabel!),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: AppSpacing.space2, runSpacing: AppSpacing.space2, children: chips);
  }

  String _workTypeLabel(String workType) => switch (workType) {
        'remote' => 'Remote',
        'hybrid' => 'Hybrid',
        'onsite' => 'Onsite',
        _ => workType,
      };

  Widget _factChip(BuildContext context, AppIconName? icon, String text, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: context.c.surface2,
        borderRadius: AppRadius.pillRadius,
        border: Border.all(color: context.c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon, size: 12, color: context.c.inkFaint),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: mono
                ? AppTypography.caption.copyWith(fontFamily: AppTypography.monoData.fontFamily, color: context.c.ink, fontWeight: FontWeight.w500)
                : AppTypography.caption.copyWith(color: context.c.ink),
          ),
        ],
      ),
    );
  }

  /// The actual signals behind the badge (Migration 031, ADR-055) — not just
  /// the generic "worth a closer look" banner the list's badge shows, since
  /// this page's whole point is showing every detail clearly.
  Widget _legitimacySection(BuildContext context) {
    final tier = job.legitimacyTier;
    final isSuspicious = tier == 'suspicious';
    final headerColor = isSuspicious ? context.c.critical : context.c.warning;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: headerColor.withValues(alpha: 0.08),
        borderRadius: AppRadius.mdRadius,
        border: Border.all(color: headerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIconName.alertTriangle, size: 15, color: headerColor),
              const SizedBox(width: 6),
              Text(
                isSuspicious ? 'Possibly fake — review before applying' : 'Verify this posting before applying',
                style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700, color: headerColor),
              ),
            ],
          ),
          for (final raw in _legitimacySignals) ...[
            const SizedBox(height: AppSpacing.space2),
            _signalRow(context, (raw as Map).cast<String, dynamic>()),
          ],
          if (_contractorNote != null) ...[
            const SizedBox(height: AppSpacing.space2),
            Text(_contractorNote!, style: AppTypography.caption.copyWith(color: context.c.inkSoft)),
          ],
        ],
      ),
    );
  }

  Widget _signalRow(BuildContext context, Map<String, dynamic> signal) {
    final weight = signal['weight'] as String? ?? 'neutral';
    final detail = signal['detail'] as String? ?? (signal['signal'] as String? ?? '');
    final color = switch (weight) {
      'concerning' => context.c.critical,
      'positive' => context.c.success,
      _ => context.c.inkFaint,
    };
    final icon = switch (weight) {
      'concerning' => AppIconName.alertTriangle,
      'positive' => AppIconName.check,
      _ => AppIconName.info,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(detail, style: AppTypography.caption.copyWith(color: context.c.inkSoft))),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final hasUrl = job.redirectUrl != null && job.redirectUrl!.isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: hasUrl
                  ? () => context.push(
                        '/form-webview',
                        extra: FormWebViewArgs(
                          browseUrl: job.redirectUrl,
                          formTitle: job.title,
                          jobId: job.id,
                          jobTitle: job.title,
                        ),
                      )
                  : null,
              icon: AppIcon(AppIconName.externalLink, size: 18, color: context.onAccent),
              label: Text(hasUrl ? 'Apply' : 'No posting link available'),
            ),
            const SizedBox(height: AppSpacing.space2),
            OutlinedButton.icon(
              onPressed: () => context.push('/tailor', extra: TailorArgs(jobId: job.id, jobTitle: job.title)),
              icon: AppIcon(AppIconName.fileText, size: 18, color: context.c.accent),
              label: const Text('Tailor résumé for this job'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Company mark: a real logo when [logoUrl] is present (loaded defensively —
/// `errorBuilder`/`loadingBuilder` so a broken or slow URL degrades to the
/// initial tile instead of a blank/broken image box), the same
/// initial-on-tinted-tile fallback [JobCard]'s own logo slot already uses
/// otherwise (every job today, until a source starts sending one — see
/// [JobDetailScreen._logoUrl]).
class _CompanyLogo extends StatelessWidget {
  const _CompanyLogo({required this.company, this.logoUrl});

  final String company;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final initial = company.trim().isEmpty ? '?' : company.trim()[0].toUpperCase();
    final fallback = Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.c.accentSoft,
        borderRadius: AppRadius.mdRadius,
        border: Border.all(color: context.c.border),
      ),
      child: Text(initial, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: context.c.accent)),
    );
    if (logoUrl == null) return fallback;
    return ClipRRect(
      borderRadius: AppRadius.mdRadius,
      child: Image.network(
        logoUrl!,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback,
        loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
      ),
    );
  }
}

/// Source-provider mark (Unstop/Internshala/Naukri/Indeed/LinkedIn/Adzuna/
/// JSearch/Greenhouse/Lever/Instahyre/…): a small deterministic
/// colour+initial badge, same posture as [_CompanyLogo]'s fallback — no
/// external brand-icon dependency (nothing to fetch, nothing to fail), just
/// enough to read at a glance which board a posting came from. An unknown
/// source (a future ingestion source, or a manually-added job) gets the same
/// neutral treatment rather than looking broken.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  static const _colors = <String, Color>{
    'unstop': Color(0xFFE94057),
    'internshala': Color(0xFF00A5EC),
    'naukri': Color(0xFF4A90D9),
    'indeed': Color(0xFF2557A7),
    'linkedin': Color(0xFF0A66C2),
    'adzuna': Color(0xFF0CAA41),
    'jsearch': Color(0xFF8E44AD),
    'greenhouse': Color(0xFF23A566),
    'lever': Color(0xFFFF6A55),
    'instahyre': Color(0xFFF5A623),
  };

  @override
  Widget build(BuildContext context) {
    final key = source.trim().toLowerCase();
    final color = _colors[key] ?? context.c.inkFaint;
    final initial = source.trim().isEmpty ? '?' : source.trim()[0].toUpperCase();
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        initial,
        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}
