import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

enum BannerTone { info, success, warning, critical }

class _ToneSpec {
  const _ToneSpec(this.bg, this.border, this.fg, this.icon);
  final Color bg;
  final Color border;
  final Color fg;
  final AppIconName icon;
}

const Map<BannerTone, _ToneSpec> _toneMap = {
  BannerTone.info: _ToneSpec(AppColors.infoSoft, AppColors.infoBorder, AppColors.infoText, AppIconName.info),
  BannerTone.success: _ToneSpec(AppColors.successSoft, AppColors.successBorder, AppColors.successText, AppIconName.check),
  BannerTone.warning: _ToneSpec(AppColors.warningSoft, AppColors.warningBorder, AppColors.warningText, AppIconName.alertTriangle),
  BannerTone.critical: _ToneSpec(AppColors.criticalSoft, AppColors.criticalBorder, AppColors.criticalText, AppIconName.alertTriangle),
};

/// Inline contextual message — e.g. the "needs follow-up" stale
/// -application warning (Brick 7) or a guardrail notice (Brick 6).
/// Tone-colored, with an optional action link and dismiss button.
///
/// ```dart
/// AppBanner(
///   tone: BannerTone.warning,
///   title: '3 applications need follow-up',
///   message: 'No activity in 7+ days.',
///   actionLabel: 'Review',
///   onAction: () => ...,
/// )
/// ```
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    this.tone = BannerTone.info,
    this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final BannerTone tone;
  final String? title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// When set, shows a dismiss button.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = _toneMap[tone]!;
    return DecoratedBox(
      decoration: BoxDecoration(color: t.bg, border: Border.all(color: t.border), borderRadius: AppRadius.mdRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: AppIcon(t.icon, size: 18, color: t.fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(title!, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700, color: t.fg)),
                  if (message != null)
                    Padding(
                      padding: EdgeInsets.only(top: title != null ? 2 : 0),
                      child: Text(
                        message!,
                        style: AppTypography.caption.copyWith(color: t.fg.withValues(alpha: 0.9)),
                      ),
                    ),
                  if (actionLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: InkWell(
                        onTap: onAction,
                        child: Text(
                          actionLabel!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: t.fg,
                            decoration: TextDecoration.underline,
                            decorationColor: t.fg,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (onDismiss != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: InkWell(
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: AppIcon(AppIconName.x, size: 16, color: t.fg.withValues(alpha: 0.7)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
