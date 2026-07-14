import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The FirstRole mark: a three-step staircase with an arrow rising off it.
///
/// This is the same geometry as the launcher icon (see
/// `app/assets/icon/icon.png`), redrawn in Dart so in-app brand surfaces and the
/// home-screen icon agree. Before this existed the splash showed a *target*
/// glyph from the generic icon set, which read as a different product.
///
/// Draws in [color] on a transparent ground; put it on the brand fill yourself.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BrandMarkPainter(color)),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  _BrandMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // The staircase occupies the lower-left; the arrow needs the upper-right,
    // so the steps sit below and left of centre to keep the whole mark
    // optically centred in the box.
    final box = size.width * 0.72;
    final ox = size.width * 0.02;
    final oy = size.height * 0.26;
    final stepW = box / 3;
    final baseline = oy + box;
    final r = Radius.circular(box * 0.055);
    const heights = [0.36, 0.64, 1.0];

    // Three rounded rects on a shared baseline. They touch, so they merge into
    // one silhouette — separated bars would read as a bar chart, not stairs.
    for (var i = 0; i < 3; i++) {
      final h = box * heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(ox + i * stepW, baseline - h, stepW, h),
          r,
        ),
        paint,
      );
      // Square off the internal join so the union has no notch in it.
      if (i < 2) {
        canvas.drawRect(
          Rect.fromLTWH(ox + (i + 1) * stepW - r.x * 2, baseline - h, r.x * 2, h),
          paint,
        );
      }
    }

    // Arrow: 45-degree shaft with a triangular head, clear of the top step.
    const dir = math.pi / 4; // up-and-right
    final ux = math.cos(-dir), uy = math.sin(-dir);
    final px = -uy, py = ux; // perpendicular

    final shaftT = box * 0.095;
    final shaftLen = box * 0.34;
    final headLen = box * 0.17;
    final headW = box * 0.088;

    final tailX = ox + box * 0.80;
    final tailY = oy - box * 0.16;
    final endX = tailX + ux * shaftLen;
    final endY = tailY + uy * shaftLen;
    final tipX = tailX + ux * (shaftLen + headLen);
    final tipY = tailY + uy * (shaftLen + headLen);

    canvas.drawLine(
      Offset(tailX, tailY),
      Offset(endX, endY),
      Paint()
        ..color = color
        ..strokeWidth = shaftT
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Head base is pulled slightly back along the shaft so there is no seam.
    final bx = endX - ux * shaftT * 0.35;
    final by = endY - uy * shaftT * 0.35;
    canvas.drawPath(
      Path()
        ..moveTo(tipX, tipY)
        ..lineTo(bx + px * headW, by + py * headW)
        ..lineTo(bx - px * headW, by - py * headW)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) => old.color != color;
}
