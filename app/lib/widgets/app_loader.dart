import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// The app's loading indicator: three ascending bars that fill in sequence,
/// echoing the staircase in the launcher icon.
///
/// Replaces the stock [CircularProgressIndicator], which is Material's
/// generic spinner and carries none of the brand. Use [AppLoader.small] inside
/// buttons and rows; the default size suits a full-screen wait.
///
/// Two things worth knowing if you touch this:
/// - It is **indeterminate on purpose.** We cannot honestly predict how long a
///   rerank takes (a cold batch is minutes), and a progress bar that stalls at
///   90% is worse than one that never claimed to know.
/// - It collapses to a static mark under the OS "reduce motion" setting.
class AppLoader extends StatefulWidget {
  const AppLoader({super.key, this.size = 64, this.color = AppColors.brand600});

  /// Compact variant for buttons and inline rows.
  const AppLoader.small({super.key, this.color = AppColors.brand600}) : size = 20;

  /// Height of the tallest bar; the widget lays out at roughly [size] square.
  final double size;
  final Color color;

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: reduceMotion
          ? CustomPaint(painter: _StairsPainter(phase: 0, color: widget.color, static_: true))
          : AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                painter: _StairsPainter(phase: _controller.value, color: widget.color),
              ),
            ),
    );
  }
}

class _StairsPainter extends CustomPainter {
  _StairsPainter({required this.phase, required this.color, this.static_ = false});

  /// 0.0 → 1.0, one full pass of the wave across the three bars.
  final double phase;
  final Color color;

  /// Reduce-motion: draw all bars at rest, no wave.
  final bool static_;

  static const _heights = [0.42, 0.68, 1.0];
  static const _minOpacity = 0.28;

  @override
  void paint(Canvas canvas, Size size) {
    final barW = size.width * 0.235;
    final gap = (size.width - barW * 3) / 2;
    final radius = Radius.circular(barW * 0.3);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < 3; i++) {
      final h = size.height * _heights[i];
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (barW + gap), size.height - h, barW, h),
        radius,
      );

      // Each bar trails the one before it by a third of the cycle, so the
      // brightness climbs the staircase rather than blinking all at once.
      final double opacity;
      if (static_) {
        opacity = 0.55;
      } else {
        final t = (phase - i * 0.18) % 1.0;
        // A single smooth pulse per cycle: rises, peaks, falls, then rests.
        final wave = math.sin(t * math.pi).clamp(0.0, 1.0).toDouble();
        opacity = _minOpacity + (1 - _minOpacity) * wave;
      }

      canvas.drawRRect(rect, paint..color = color.withValues(alpha: opacity));
    }
  }

  @override
  bool shouldRepaint(_StairsPainter old) =>
      old.phase != phase || old.color != color || old.static_ != static_;
}
