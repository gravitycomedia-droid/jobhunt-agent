import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'loading_skeleton.dart';

/// Phase 4C: structure-matched skeletons, one per screen shape, all
/// composed from [LoadingSkeleton]'s shimmer primitives and tokens. A
/// skeleton that mirrors the real layout stops the "jump" when content
/// lands; the generic [LoadingSkeleton] card/line variants remain the
/// fallback for anything without a dedicated shape.

/// Card frame shared by the skeleton shapes below — same border/radius/
/// padding as the real cards.
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Padding(padding: const EdgeInsets.all(AppSpacing.space4), child: child),
    );
  }
}

/// Jobs list: avatar square + two text lines + chip row. (The existing
/// `SkeletonVariant.card` already has exactly this shape — this named
/// wrapper exists so call sites read as intent.)
class JobCardSkeleton extends StatelessWidget {
  const JobCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const LoadingSkeleton(variant: SkeletonVariant.card);
}

/// Matches: avatar + title lines + a circular score-ring placeholder.
class MatchCardSkeleton extends StatelessWidget {
  const MatchCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return _SkeletonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const LoadingSkeleton(variant: SkeletonVariant.block, width: 42, height: 42),
              const SizedBox(width: AppSpacing.space3),
              const Expanded(child: LoadingSkeleton(variant: SkeletonVariant.line, count: 2)),
              const SizedBox(width: AppSpacing.space3),
              const LoadingSkeleton(variant: SkeletonVariant.circle, size: 52),
            ],
          ),
          const SizedBox(height: AppSpacing.space3),
          Row(
            children: const [
              LoadingSkeleton(variant: SkeletonVariant.block, width: 96, height: 20),
              SizedBox(width: AppSpacing.space2),
              LoadingSkeleton(variant: SkeletonVariant.block, width: 72, height: 20),
            ],
          ),
        ],
      ),
    );
  }
}

/// Track: column headers + a few card blocks per Kanban column.
class KanbanSkeleton extends StatelessWidget {
  const KanbanSkeleton({super.key, this.columns = 4});

  final int columns;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      itemCount: columns,
      separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.space3),
      itemBuilder: (_, _) => SizedBox(
        width: 264,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            LoadingSkeleton(variant: SkeletonVariant.block, height: 24),
            SizedBox(height: AppSpacing.space3),
            LoadingSkeleton(variant: SkeletonVariant.block, height: 84),
            SizedBox(height: AppSpacing.space3),
            LoadingSkeleton(variant: SkeletonVariant.block, height: 84),
            SizedBox(height: AppSpacing.space3),
            LoadingSkeleton(variant: SkeletonVariant.block, height: 84),
          ],
        ),
      ),
    );
  }
}

/// Home: greeting lines + hero match card + the 3-stat grid.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: const [
        LoadingSkeleton(variant: SkeletonVariant.line, count: 2, height: 16),
        SizedBox(height: AppSpacing.space4),
        HeroCardSkeleton(),
        SizedBox(height: AppSpacing.space4),
        StatGridSkeleton(),
      ],
    );
  }
}

/// Home's "best match" hero: big score ring + text lines.
class HeroCardSkeleton extends StatelessWidget {
  const HeroCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const _SkeletonCard(
      child: Row(
        children: [
          LoadingSkeleton(variant: SkeletonVariant.circle, size: 84),
          SizedBox(width: AppSpacing.space4),
          Expanded(child: LoadingSkeleton(variant: SkeletonVariant.line, count: 3)),
        ],
      ),
    );
  }
}

/// Home's 3-tile stat row.
class StatGridSkeleton extends StatelessWidget {
  const StatGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        Expanded(child: LoadingSkeleton(variant: SkeletonVariant.block, height: 68)),
        SizedBox(width: AppSpacing.space2),
        Expanded(child: LoadingSkeleton(variant: SkeletonVariant.block, height: 68)),
        SizedBox(width: AppSpacing.space2),
        Expanded(child: LoadingSkeleton(variant: SkeletonVariant.block, height: 68)),
      ],
    );
  }
}

/// Profile/ProfileReview: avatar circle + field rows.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _SkeletonCard(
          child: Row(
            children: const [
              LoadingSkeleton(variant: SkeletonVariant.circle, size: 56),
              SizedBox(width: AppSpacing.space3),
              Expanded(child: LoadingSkeleton(variant: SkeletonVariant.line, count: 2)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.space4),
        for (var i = 0; i < 4; i++) ...[
          const LoadingSkeleton(variant: SkeletonVariant.block, height: 52),
          const SizedBox(height: AppSpacing.space3),
        ],
      ],
    );
  }
}

/// ResumeDiffScreen while tailoring loads: original/tailored bullet pair.
class DiffRowSkeleton extends StatelessWidget {
  const DiffRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const _SkeletonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoadingSkeleton(variant: SkeletonVariant.line, count: 2),
          SizedBox(height: AppSpacing.space3),
          LoadingSkeleton(variant: SkeletonVariant.line, count: 2),
        ],
      ),
    );
  }
}
