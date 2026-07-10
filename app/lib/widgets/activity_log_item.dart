import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

enum ActivityKind { agent, match, applied, warning, rejected, info }

class _KindSpec {
  const _KindSpec(this.icon, this.bg, this.fg);
  final AppIconName icon;
  final Color bg;
  final Color fg;
}

const Map<ActivityKind, _KindSpec> _kindMap = {
  ActivityKind.agent: _KindSpec(AppIconName.bot, AppColors.brandSoft, AppColors.brand700),
  ActivityKind.match: _KindSpec(AppIconName.target, AppColors.infoSoft, AppColors.infoText),
  ActivityKind.applied: _KindSpec(AppIconName.check, AppColors.successSoft, AppColors.successText),
  ActivityKind.warning: _KindSpec(AppIconName.alertTriangle, AppColors.warningSoft, AppColors.warningText),
  ActivityKind.rejected: _KindSpec(AppIconName.x, AppColors.criticalSoft, AppColors.criticalText),
  ActivityKind.info: _KindSpec(AppIconName.info, AppColors.neutralSoft, AppColors.neutralText),
};

/// One entry in the Agent Activity Log (Brick 8): icon by [kind], title,
/// optional detail, right-aligned timestamp, connected to neighboring
/// entries by a timeline rail unless [last].
///
/// ```dart
/// ActivityLogItem(
///   kind: ActivityKind.agent,
///   title: 'Daily pipeline ran',
///   detail: '5 new matches found',
///   timestamp: '2h ago',
/// )
/// ```
class ActivityLogItem extends StatelessWidget {
  const ActivityLogItem({
    super.key,
    this.kind = ActivityKind.info,
    required this.title,
    this.detail,
    this.timestamp,
    this.last = false,
  });

  final ActivityKind kind;
  final String title;
  final String? detail;

  /// Right-aligned timestamp (mono), e.g. "2h ago".
  final String? timestamp;

  /// Last item — hides the connecting rail.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final spec = _kindMap[kind]!;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: spec.bg, shape: BoxShape.circle),
                child: AppIcon(spec.icon, size: 16, color: spec.fg),
              ),
              if (!last)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(width: 2, color: AppColors.border),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (timestamp != null)
                        Text(
                          timestamp!,
                          style: TextStyle(
                            fontFamily: AppTypography.monoData.fontFamily,
                            fontSize: 11,
                            color: AppColors.textTertiary,
                          ),
                        ),
                    ],
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(detail!, style: AppTypography.caption.copyWith(height: 18 / 13)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
