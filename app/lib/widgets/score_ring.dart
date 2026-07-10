import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class _Tone {
  const _Tone(this.stroke, this.text);
  final Color stroke;
  final Color text;
}

/// Score → verdict tone, mirrors [StatusPill]'s verdict mapping
/// (≥75 apply/green · ≥50 stretch/amber · <50 skip/red).
_Tone _toneFor(int score) {
  if (score >= 75) return const _Tone(AppColors.successFill, AppColors.successText);
  if (score >= 50) return const _Tone(AppColors.warningFill, AppColors.warningText);
  return const _Tone(AppColors.criticalFill, AppColors.criticalText);
}

/// Circular match-score gauge. Color follows the verdict thresholds
/// unless [color] overrides it.
///
/// ```dart
/// ScoreRing(score: 82)
/// ScoreRing(score: 61, size: 40, showLabel: false)
/// ```
class ScoreRing extends StatelessWidget {
  const ScoreRing({
    super.key,
    required this.score,
    this.size = 56,
    this.thickness = 5,
    this.color,
    this.showLabel = true,
  });

  /// Match score 0–100.
  final num score;
  final double size;
  final double thickness;

  /// Overrides the auto verdict color.
  final Color? color;

  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final v = score.round().clamp(0, 100);
    final tone = _toneFor(v);
    final stroke = color ?? tone.stroke;

    return SizedBox(
      width: size,
      height: size,
      child: Semantics(
        label: 'Match score $v percent',
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size(size, size),
              painter: _RingPainter(value: v, thickness: thickness, trackColor: AppColors.neutral200, fillColor: stroke),
            ),
            if (showLabel)
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '$v',
                      style: TextStyle(
                        fontFamily: AppTypography.monoData.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: size >= 52 ? 16 : 12,
                        color: tone.text,
                        letterSpacing: -0.02 * (size >= 52 ? 16 : 12),
                      ),
                    ),
                    TextSpan(
                      text: '%',
                      style: TextStyle(
                        fontFamily: AppTypography.monoData.fontFamily,
                        fontSize: size >= 52 ? 9 : 7,
                        color: tone.text.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.value, required this.thickness, required this.trackColor, required this.fillColor});

  final int value;
  final double thickness;
  final Color trackColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - thickness) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);

    final fill = Paint()
      ..color = fillColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    final sweep = 2 * math.pi * (value / 100);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, fill);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.fillColor != fillColor || oldDelegate.thickness != thickness;
}
