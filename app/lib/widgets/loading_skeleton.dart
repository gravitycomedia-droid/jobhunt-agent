import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../theme/app_tokens.dart';

enum SkeletonVariant { line, block, circle, card }

/// A single ticker shared by every skeleton on screen.
///
/// Previously each [LoadingSkeleton] owned its own `AnimationController`, so a
/// list of 8 skeleton cards ran 8 tickers that each started whenever their
/// widget happened to mount. Their shimmer waves drifted out of phase and the
/// page glittered instead of sweeping — and 7 of those 8 tickers were pure
/// waste. Everything now reads one clock, so the highlight crosses the page as
/// one wave.
///
/// It is ref-counted: the ticker starts on the first skeleton to mount and is
/// disposed when the last one leaves, so a screen with no skeletons on it costs
/// nothing per frame.
class _ShimmerClock extends ChangeNotifier {
  _ShimmerClock._();

  static final _ShimmerClock instance = _ShimmerClock._();

  /// One full left-to-right sweep.
  static const Duration period = Duration(milliseconds: 1300);

  Ticker? _ticker;
  int _mounted = 0;
  double _value = 0;

  /// Phase of the sweep, 0.0 → 1.0.
  double get value => _value;

  void acquire() {
    _mounted++;
    _ticker ??= Ticker(_onTick)..start();
  }

  void release() {
    _mounted--;
    if (_mounted > 0) return;
    _mounted = 0;
    _ticker?.dispose();
    _ticker = null;
    _value = 0;
  }

  void _onTick(Duration elapsed) {
    final p = period.inMicroseconds;
    _value = (elapsed.inMicroseconds % p) / p;
    notifyListeners();
  }
}

/// Shimmer placeholder for loading states.
///
/// - `line` — one or more text-line bars (set [count]/[width]/[height])
/// - `block` — a rectangle (set [width]/[height])
/// - `circle` — an avatar/ring (set [size])
/// - `card` — a full JobCard-shaped placeholder
///
/// ```dart
/// LoadingSkeleton(variant: SkeletonVariant.card)
/// LoadingSkeleton(variant: SkeletonVariant.line, count: 3)
/// ```
class LoadingSkeleton extends StatefulWidget {
  const LoadingSkeleton({
    super.key,
    this.variant = SkeletonVariant.line,
    this.width,
    this.height,
    this.size = 42,
    this.count = 1,
  });

  final SkeletonVariant variant;
  final double? width;
  final double? height;

  /// Diameter for [SkeletonVariant.circle]. Default 42.
  final double size;

  /// Number of lines for [SkeletonVariant.line]. Default 1.
  final int count;

  @override
  State<LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<LoadingSkeleton> {
  // This widget is stateful purely to hold the shared clock's ref-count across
  // its lifetime — it has no state of its own.
  @override
  void initState() {
    super.initState();
    _ShimmerClock.instance.acquire();
  }

  @override
  void dispose() {
    _ShimmerClock.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.variant) {
      case SkeletonVariant.circle:
        return _Shimmer(
          borderRadius: BorderRadius.circular(widget.size / 2),
          child: SizedBox(width: widget.size, height: widget.size),
        );
      case SkeletonVariant.block:
        return _Shimmer(
          borderRadius: AppRadius.mdRadius,
          child: SizedBox(width: widget.width ?? double.infinity, height: widget.height ?? 80),
        );
      case SkeletonVariant.card:
        return const _CardSkeleton();
      case SkeletonVariant.line:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.count; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                // Last line of a paragraph runs short, like real text does.
                widthFactor: (i == widget.count - 1 && widget.count > 1) ? 0.6 : 1,
                child: _Shimmer(
                  borderRadius: AppRadius.smRadius,
                  child: SizedBox(height: widget.height ?? 12),
                ),
              ),
            ],
          ],
        );
    }
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Shimmer(borderRadius: AppRadius.mdRadius, child: const SizedBox(width: 42, height: 42)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Shimmer(borderRadius: AppRadius.smRadius, child: const SizedBox(height: 14)),
                      const SizedBox(height: 7),
                      FractionallySizedBox(
                        widthFactor: 0.45,
                        alignment: Alignment.centerLeft,
                        child: _Shimmer(borderRadius: AppRadius.smRadius, child: const SizedBox(height: 11)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Shimmer(borderRadius: AppRadius.pillRadius, child: const SizedBox(width: 90, height: 20)),
                const SizedBox(width: 8),
                _Shimmer(borderRadius: AppRadius.pillRadius, child: const SizedBox(width: 70, height: 20)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.borderRadius, required this.child});

  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Respect the OS "reduce motion" setting: a sweeping highlight is exactly
    // the kind of looping animation it exists to suppress. Fall back to a flat
    // bar, which still communicates "loading" via shape alone.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(color: AppColors.neutral200, child: child),
      );
    }

    return AnimatedBuilder(
      animation: _ShimmerClock.instance,
      builder: (context, _) {
        final t = _ShimmerClock.instance.value;
        return ClipRRect(
          borderRadius: borderRadius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // A LIGHT highlight travelling across a slightly darker bar. The
              // previous gradient swept neutral200 (darker) over neutral100, so
              // the moving band read as a shadow rather than a sheen.
              gradient: LinearGradient(
                begin: Alignment(-1 + 3 * t, 0),
                end: Alignment(1 + 3 * t, 0),
                colors: const [AppColors.neutral200, AppColors.neutral50, AppColors.neutral200],
                stops: const [0.3, 0.5, 0.7],
              ),
            ),
            child: child,
          ),
        );
      },
    );
  }
}
