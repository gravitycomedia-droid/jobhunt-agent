import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum SkeletonVariant { line, block, circle, card }

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

class _LoadingSkeletonState extends State<LoadingSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.variant) {
      case SkeletonVariant.circle:
        return _Shimmer(controller: _controller, borderRadius: BorderRadius.circular(widget.size / 2), child: SizedBox(width: widget.size, height: widget.size));
      case SkeletonVariant.block:
        return _Shimmer(
          controller: _controller,
          borderRadius: AppRadius.mdRadius,
          child: SizedBox(width: widget.width ?? double.infinity, height: widget.height ?? 80),
        );
      case SkeletonVariant.card:
        return _CardSkeleton(controller: _controller);
      case SkeletonVariant.line:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.count; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (i == widget.count - 1 && widget.count > 1) ? 0.6 : 1,
                child: _Shimmer(
                  controller: _controller,
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
  const _CardSkeleton({required this.controller});

  final AnimationController controller;

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
                _Shimmer(controller: controller, borderRadius: AppRadius.mdRadius, child: const SizedBox(width: 42, height: 42)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Shimmer(controller: controller, borderRadius: AppRadius.smRadius, child: const SizedBox(height: 14)),
                      const SizedBox(height: 7),
                      FractionallySizedBox(
                        widthFactor: 0.45,
                        alignment: Alignment.centerLeft,
                        child: _Shimmer(controller: controller, borderRadius: AppRadius.smRadius, child: const SizedBox(height: 11)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Shimmer(controller: controller, borderRadius: AppRadius.pillRadius, child: const SizedBox(width: 90, height: 20)),
                const SizedBox(width: 8),
                _Shimmer(controller: controller, borderRadius: AppRadius.pillRadius, child: const SizedBox(width: 70, height: 20)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.controller, required this.borderRadius, required this.child});

  final AnimationController controller;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        return ClipRRect(
          borderRadius: borderRadius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-1 + 3 * t, 0),
                end: Alignment(1 + 3 * t, 0),
                colors: const [AppColors.neutral100, AppColors.neutral200, AppColors.neutral100],
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
