import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/referral_stats.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// Plan 21: the invite screen — the user's own code, a share sheet, and what
/// their referrals have earned them.
///
/// No deep-link handling in v1 by decision: the share message carries the code
/// as text and the recipient types it into onboarding. That keeps the whole
/// feature inside the app with no URL scheme, no App Links/Universal Links
/// setup, and nothing to configure per store listing.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  final ApiClient _apiClient = ApiClient();
  bool _isLoading = true;
  String? _errorMessage;
  ReferralStats? _stats;

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
      final stats = await _apiClient.fetchReferralStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
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

  String _shareMessage(String code) =>
      "I'm using FirstRole to find and score jobs against my resume — it "
      "actually explains why each one fits.\n\n"
      "Use my invite code $code when you sign up and we both get 5 extra "
      "full match analyses.";

  Future<void> _share(String code) async {
    // share_plus routes to the OS share sheet (WhatsApp, etc.) — the native
    // equivalent of FlutterFlow's "Share" action. sharePositionOrigin is
    // required on iPad, where the sheet is a popover anchored to a rect; the
    // same pattern resume_preview_screen.dart already uses.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await Share.share(_shareMessage(code), sharePositionOrigin: origin);
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite code copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeader(title: 'Invite friends', subtitle: 'Unlock more full match analyses'),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) return const Center(child: AppLoader());

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load your invite code',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final stats = _stats;
    final code = stats?.referralCode;
    if (stats == null || code == null || code.isEmpty) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'No invite code yet',
          message: 'Your code is still being set up. Pull back in a moment.',
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
      children: [
        _CodeCard(code: code, onCopy: () => _copy(code), onShare: () => _share(code)),
        const SizedBox(height: AppSpacing.space4),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                value: '${stats.referredCount}',
                label: stats.referredCount == 1 ? 'Friend joined' : 'Friends joined',
              ),
            ),
            const SizedBox(width: AppSpacing.space3),
            Expanded(child: _StatTile(value: '+${stats.bonusMatchQuota}', label: 'Bonus matches')),
          ],
        ),
        const SizedBox(height: AppSpacing.space4),
        Container(
          padding: const EdgeInsets.all(AppSpacing.space4),
          decoration: BoxDecoration(
            color: context.c.surface,
            border: Border.all(color: context.c.border),
            borderRadius: AppRadius.lgRadius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('How it works', style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpacing.space2),
              _Bullet(text: 'Share your code with a friend.'),
              _Bullet(text: 'They enter it when they sign up.'),
              _Bullet(text: 'You both get 5 more full match analyses — instantly.'),
              const SizedBox(height: AppSpacing.space3),
              Text(
                "You're currently getting ${stats.effectiveMatchLimit} full analyses.",
                style: AppTypography.caption.copyWith(color: context.c.inkSoft),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.onCopy, required this.onShare});
  final String code;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.space5),
      decoration: BoxDecoration(
        color: context.c.accentSoft,
        borderRadius: AppRadius.lgRadius,
      ),
      child: Column(
        children: [
          Text('YOUR INVITE CODE', style: AppTypography.caption.copyWith(color: context.c.inkSoft, letterSpacing: 1.2)),
          const SizedBox(height: AppSpacing.space2),
          // Mono + wide letter spacing: this is a string people read aloud and
          // retype, so character-by-character legibility beats prettiness.
          SelectableText(
            code,
            style: TextStyle(
              fontFamily: AppTypography.monoData.fontFamily,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: context.c.accent,
            ),
          ),
          const SizedBox(height: AppSpacing.space4),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const AppIcon(AppIconName.copy, size: 16),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: AppSpacing.space2),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onShare,
                  icon: const AppIcon(AppIconName.share, size: 16),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontFamily: AppTypography.monoData.fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: AppTypography.caption.copyWith(color: context.c.inkSoft)),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AppIcon(AppIconName.check, size: 14, color: context.c.accent),
          ),
          const SizedBox(width: AppSpacing.space2),
          Expanded(child: Text(text, style: AppTypography.bodySm.copyWith(color: context.c.inkSoft))),
        ],
      ),
    );
  }
}
