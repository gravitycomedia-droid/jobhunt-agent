import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'status_pill.dart';

/// One pipeline lane for the Applications Kanban board (Brick 7).
/// Header shows the stage pill + count; [children] are the application
/// cards, scrollable within the column's max height.
///
/// ```dart
/// KanbanColumn(
///   stage: 'interview',
///   children: applications.map((a) => ApplicationCard(a)).toList(),
/// )
/// ```
class KanbanColumn extends StatelessWidget {
  const KanbanColumn({
    super.key,
    required this.stage,
    this.count,
    this.width = 264,
    this.children = const [],
  });

  /// Pipeline stage this lane represents (new/applied/replied/interview/offer/rejected).
  final String stage;

  /// Card count in the header; defaults to `children.length`.
  final int? count;

  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final n = count ?? children.length;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                StatusPill(context: PillContext.stage, value: stage, size: PillSize.sm),
                const Spacer(),
                Text(
                  '$n',
                  style: TextStyle(
                    fontFamily: AppTypography.monoData.fontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in children) ...[
                    child,
                    if (child != children.last) const SizedBox(height: AppSpacing.space2),
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
