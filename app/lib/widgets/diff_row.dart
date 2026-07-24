import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
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
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.mdRadius,
        color: context.c.surface,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.mdRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // original
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.c.surface2,
                border: Border(bottom: BorderSide(color: context.c.border)),
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
                        color: context.c.inkFaint,
                        height: 20 / 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        original,
                        style: AppTypography.bodySm.copyWith(
                          color: context.c.inkFaint,
                          decoration: unchanged ? TextDecoration.none : TextDecoration.lineThrough,
                          decorationColor: context.c.border,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // tailored
            DecoratedBox(
              decoration: BoxDecoration(color: guardrailFail ? context.c.critical.withValues(alpha: 0.12) : Colors.transparent),
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
                        color: guardrailFail ? context.c.critical : context.c.success,
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
                                ? BoxDecoration(color: context.c.critical.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(3))
                                : null,
                            child: Text(
                              tailored,
                              style: AppTypography.bodySm.copyWith(
                                fontWeight: FontWeight.w500,
                                color: guardrailFail ? context.c.critical : context.c.ink,
                              ),
                            ),
                          ),
                          if (guardrailFail) ...[
                            const SizedBox(width: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(AppIconName.alertTriangle, size: 12, color: context.c.critical),
                                SizedBox(width: 4),
                                Text(
                                  'Guardrail fail',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.c.critical),
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
