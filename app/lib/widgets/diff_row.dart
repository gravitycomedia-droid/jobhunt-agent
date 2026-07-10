import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// One tailoring change: original resume bullet vs tailored bullet.
/// When [guardrailFail] is set, the tailored text is highlighted
/// critical — a fabricated / unverifiable claim `guardrail.py` rejected
/// (see ADR-004 and CLAUDE.md's anti-fabrication golden rule).
///
/// ```dart
/// DiffRow(
///   original: 'Managed a small team',
///   tailored: 'Led a cross-functional team of 12 engineers',
///   guardrailFail: true,
/// )
/// ```
class DiffRow extends StatelessWidget {
  const DiffRow({
    super.key,
    required this.original,
    required this.tailored,
    this.guardrailFail = false,
    this.unchanged = false,
  });

  /// The original resume bullet (struck-through unless [unchanged]).
  final String original;

  /// The AI-tailored replacement.
  final String tailored;

  /// Highlight the tailored text critical — a guardrail-rejected claim.
  final bool guardrailFail;

  /// Suppress the strike-through on the original (kept as-is).
  final bool unchanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.mdRadius,
        color: AppColors.surface,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.mdRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // original
            DecoratedBox(
              decoration: const BoxDecoration(
                color: AppColors.neutral50,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '–',
                      style: TextStyle(
                        fontFamily: AppTypography.monoData.fontFamily,
                        fontWeight: FontWeight.w700,
                        color: AppColors.neutral400,
                        height: 20 / 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        original,
                        style: AppTypography.bodySm.copyWith(
                          color: AppColors.textTertiary,
                          decoration: unchanged ? TextDecoration.none : TextDecoration.lineThrough,
                          decorationColor: AppColors.neutral300,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // tailored
            DecoratedBox(
              decoration: BoxDecoration(color: guardrailFail ? AppColors.criticalSoft : Colors.transparent),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '+',
                      style: TextStyle(
                        fontFamily: AppTypography.monoData.fontFamily,
                        fontWeight: FontWeight.w700,
                        color: guardrailFail ? AppColors.criticalFill : AppColors.successFill,
                        height: 20 / 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: guardrailFail ? const EdgeInsets.symmetric(horizontal: 3, vertical: 1) : EdgeInsets.zero,
                            decoration: guardrailFail
                                ? BoxDecoration(color: AppColors.guardrailFailHighlight, borderRadius: BorderRadius.circular(3))
                                : null,
                            child: Text(
                              tailored,
                              style: AppTypography.bodySm.copyWith(
                                fontWeight: FontWeight.w500,
                                color: guardrailFail ? AppColors.criticalText : AppColors.textPrimary,
                              ),
                            ),
                          ),
                          if (guardrailFail) ...[
                            const SizedBox(width: 6),
                            const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(AppIconName.alertTriangle, size: 12, color: AppColors.criticalText),
                                SizedBox(width: 4),
                                Text(
                                  'Guardrail fail',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.criticalText),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
