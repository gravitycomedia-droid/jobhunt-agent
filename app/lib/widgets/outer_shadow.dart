import 'package:flutter/material.dart';

/// Casts [shadows] **outside** a rounded rectangle only, leaving the interior
/// completely untouched — the one thing `BoxDecoration.boxShadow` cannot do.
///
/// Why this exists: Flutter paints a [BoxShadow] as a blurred *filled*
/// rounded-rect sitting behind the box. When the box has an opaque fill that
/// fill hides it, so nobody notices. On a **transparent** box the shadow shows
/// straight through and washes the whole interior grey — which is exactly what
/// used to make the job cards render `#E6E6E7` even though they were declared
/// white. Clipping the shadow to the region outside the shape gives a real drop
/// shadow on a see-through surface.
///
/// Dart/Flutter note: [CustomPaint] paints its `painter` *behind* its child, so
/// the shadow lands under the card without needing an extra Stack.
class OuterShadow extends StatelessWidget {
  const OuterShadow({super.key, required this.borderRadius, required this.shadows, required this.child});

  final BorderRadius borderRadius;
  final List<BoxShadow> shadows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (shadows.isEmpty) return child;
    // RepaintBoundary: this custom painter runs on every JobCard/MatchCard
    // AND their source chip — two Path.combine boolean-clip ops per row, many
    // rows in a scrolling ListView. Giving each its own compositing layer is
    // the standard mitigation for scroll-time rendering artifacts around
    // repeated complex-path painters on iOS's Impeller renderer, and is safe
    // regardless of whether that's the actual cause here.
    return RepaintBoundary(
      child: CustomPaint(painter: _OuterShadowPainter(borderRadius, shadows), child: child),
    );
  }
}

class _OuterShadowPainter extends CustomPainter {
  const _OuterShadowPainter(this.borderRadius, this.shadows);

  final BorderRadius borderRadius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final rrect = borderRadius.toRRect(bounds);

    // How far out any shadow can reach — the clip's outer ring must cover it.
    var reach = 0.0;
    for (final s in shadows) {
      final d = s.blurRadius + s.spreadRadius + s.offset.distance;
      if (d > reach) reach = d;
    }

    // dart:ui's clipRRect has no ClipOp, so build "everything except the card"
    // as an explicit path difference and clip to that.
    final hole = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds.inflate(reach + 1)),
      Path()..addRRect(rrect),
    );

    canvas.save();
    canvas.clipPath(hole);
    for (final s in shadows) {
      canvas.drawRRect(rrect.shift(s.offset).inflate(s.spreadRadius), s.toPaint());
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter old) => old.borderRadius != borderRadius || old.shadows != shadows;
}
