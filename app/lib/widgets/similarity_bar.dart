import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';

/// Horizontal 0–100 bar for resume↔job similarity, keyword coverage,
/// etc. Color follows the same verdict thresholds as [ScoreRing]
/// unless [color] overrides it.
///
/// ```dart
/// SimilarityBar(value: 78, label: 'Semantic similarity')
/// ```
class SimilarityBar extends StatelessWidget {
  const SimilarityBar({
    super.key,
    required this.value,
    this.label,
    this.showValue = true,
    this.color,
    this.height = 8,
  });

  final num value;
  final String? label;
  final bool showValue;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final v = value.round().clamp(0, 100);
    final fill = color ?? (v >= 75 ? context.c.success : v >= 50 ? context.c.warning : context.c.critical);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null || showValue)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (label != null)
                  Expanded(
                    child: Text(
                      label!,
                      style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                if (showValue)
                  Text(
                    '$v%',
                    style: TextStyle(
                      fontFamily: AppTypography.monoData.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.c.ink,
                    ),
                  ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: AppRadius.pillRadius,
          child: LinearProgressIndicator(
            value: v / 100,
            minHeight: height,
            backgroundColor: context.c.border,
            valueColor: AlwaysStoppedAnimation(fill),
          ),
        ),
      ],
    );
  }
}
