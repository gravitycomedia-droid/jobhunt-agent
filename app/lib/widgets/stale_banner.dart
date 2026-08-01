import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import 'app_icon.dart';

/// Shown when a screen is painting cached data because the fresh fetch failed.
///
/// Previously this was a yellow "Showing saved data · could not reach the
/// server" warning banner. Per product direction it's now a quiet, non-alarming
/// "Updated {relative}" line with a subtle tap-to-refresh — the app already
/// works offline from cache, so a warning modal overstated the problem. Tapping
/// re-runs the fetch (same `onRetry` callback the banner used).
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
    final muted = context.c.inkFaint;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: AppRadius.pillRadius,
        onTap: () {
          HapticService.instance.selection();
          onRetry();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(AppIconName.refresh, size: 12, color: muted),
              const SizedBox(width: 6),
              Text(
                'Updated $_relative',
                style: AppTypography.bodySm.copyWith(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
