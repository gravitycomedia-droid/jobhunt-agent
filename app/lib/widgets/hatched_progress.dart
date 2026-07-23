import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Phase 3 — résumé-completion / progress bar (FLUTTER_GUIDE §7).
///
/// The filled portion is a solid `accent` bar; the remainder is a diagonally
/// hatched track — the signature "still to go" texture from the prototype. All
/// colours are theme tokens, so it reads correctly in both themes.
class HatchedProgress extends StatelessWidget {
  const HatchedProgress({super.key, required this.value, this.height = 10});

  /// 0.0 – 1.0.
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _HatchPainter(
            frac: value.clamp(0.0, 1.0),
            fill: c.accent,
            track: c.surface2,
            hatch: c.border,
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter({required this.frac, required this.fill, required this.track, required this.hatch});

  final double frac;
  final Color fill;
  final Color track;
  final Color hatch;

  @override
  void paint(Canvas canvas, Size size) {
    final splitX = size.width * frac;

    // Remainder: track background + diagonal hatch lines.
    final remainder = Rect.fromLTWH(splitX, 0, size.width - splitX, size.height);
    canvas.drawRect(remainder, Paint()..color = track);
    canvas.save();
    canvas.clipRect(remainder);
    final line = Paint()
      ..color = hatch
      ..strokeWidth = 1.5;
    const step = 7.0;
    for (double x = splitX - size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    canvas.restore();

    // Filled portion on top.
    canvas.drawRect(Rect.fromLTWH(0, 0, splitX, size.height), Paint()..color = fill);
  }

  @override
  bool shouldRepaint(_HatchPainter o) =>
      o.frac != frac || o.fill != fill || o.track != track || o.hatch != hatch;
}
