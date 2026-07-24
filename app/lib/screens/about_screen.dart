import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/brand_mark.dart';
import '../widgets/page_header.dart';

/// §4.14 — the static About screen. Pure product identity: the FirstRole mark,
/// name/version, mission, and legal links. Nothing here is fetched.
///
/// [_appVersion] mirrors `app/pubspec.yaml` (`version: 1.0.0+1`) by hand rather
/// than pulling in package_info_plus for one string on one screen; keep them in
/// step when bumping the version.
///
/// The legal URLs are not hosted yet (PLAY_CONSOLE.md still has a
/// `<your-username>.github.io` placeholder) — Play launch (Phase 10) owns
/// standing them up. Until a link resolves, tapping it says so honestly instead
/// of opening a dead page.
const String _appVersion = '1.0.0';
const String _privacyPolicyUrl = 'https://firstrole.app/privacy'; // Phase 10: host before launch
const String _termsUrl = 'https://firstrole.app/terms'; // Phase 10: host before launch

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'About', showBack: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space5, vertical: AppSpacing.space4),
        children: [
          const SizedBox(height: AppSpacing.space3),
          _identity(context),
          const SizedBox(height: AppSpacing.space6),
          _versionCard(context),
          const SizedBox(height: AppSpacing.space5),
          _missionCard(context),
          const SizedBox(height: AppSpacing.space6),
          _legalLinks(context),
          const SizedBox(height: AppSpacing.space4),
          Text(
            '© 2026 FirstRole. All rights reserved.',
            textAlign: TextAlign.center,
            style: AppTypography.label.copyWith(color: context.c.inkFaint),
          ),
          const SizedBox(height: AppSpacing.space6),
        ],
      ),
    );
  }

  Widget _identity(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [context.c.accent, context.c.accent],
            ),
            boxShadow: [
              BoxShadow(color: context.c.accent.withValues(alpha: 0.3), blurRadius: 24, offset: Offset(0, 12)),
            ],
          ),
          child: const BrandMark(size: 46, color: Colors.white),
        ),
        const SizedBox(height: AppSpacing.space4),
        Text('FirstRole', style: AppTypography.heading),
        const SizedBox(height: 6),
        Text(
          'for Android · $_appVersion',
          style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
        ),
        const SizedBox(height: 2),
        Text(
          'AI agent for entry-level & internship roles',
          style: AppTypography.label.copyWith(
            fontFamily: AppTypography.monoData.fontFamily,
            color: context.c.inkFaint,
          ),
        ),
      ],
    );
  }

  Widget _versionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        children: [
          Text('Version', style: AppTypography.body.copyWith(fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(
            _appVersion,
            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 14, fontWeight: FontWeight.w600, color: context.c.ink),
          ),
        ],
      ),
    );
  }

  Widget _missionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'OUR MISSION',
            style: AppTypography.label.copyWith(color: context.c.accent, letterSpacing: 0.5),
          ),
          const SizedBox(height: AppSpacing.space2),
          Text(
            'Job hunting should feel like having a tireless ally, not a second job. '
            'The agent searches, ranks, and tailors while you sleep — but every '
            'decision that matters stays yours.',
            style: AppTypography.bodySm.copyWith(color: context.c.inkSoft, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _legalLinks(BuildContext context) {
    return Column(
      children: [
        _legalRow(context, 'Privacy Policy', _privacyPolicyUrl),
        const SizedBox(height: AppSpacing.space3),
        _legalRow(context, 'Terms of Service', _termsUrl),
      ],
    );
  }

  Widget _legalRow(BuildContext context, String label, String url) {
    return InkWell(
      onTap: () => _openLegal(context, label, url),
      borderRadius: AppRadius.smRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: AppTypography.body.copyWith(color: context.c.accent, fontWeight: FontWeight.w500)),
            const SizedBox(width: 4),
            AppIcon(AppIconName.externalLink, size: 14, color: context.c.accent),
          ],
        ),
      ),
    );
  }

  Future<void> _openLegal(BuildContext context, String label, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    bool ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('$label will be available at launch.'),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }
}
