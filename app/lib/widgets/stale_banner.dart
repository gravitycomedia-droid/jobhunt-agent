import 'package:flutter/material.dart';

import 'app_banner.dart';

/// Phase 5: shown when a screen is painting cached data because the fresh
/// fetch failed — "Showing saved data · last updated 2h ago" with a Retry.
class StaleBanner extends StatelessWidget {
  const StaleBanner({super.key, required this.cachedAt, required this.onRetry});

  final DateTime cachedAt;
  final VoidCallback onRetry;

  String get _relative {
    final diff = DateTime.now().difference(cachedAt);
    if (diff.inDays >= 1) return '${diff.inDays}d ago';
    if (diff.inHours >= 1) return '${diff.inHours}h ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return AppBanner(
      tone: BannerTone.warning,
      title: 'Showing saved data',
      message: 'Could not reach the server · last updated $_relative.',
      actionLabel: 'Retry',
      onAction: onRetry,
    );
  }
}
