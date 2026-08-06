import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/locked_match_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import 'app_icon.dart';

/// Plan 21: a match past the profile's quota.
///
/// The title/company and stage-1 similarity are shown plainly — those are real
/// and cost nothing. What's blurred is a set of PLACEHOLDER bars standing in
/// for the fit score and reasoning, because the LLM never scored this job:
/// there is no hidden value to reveal, only one that referring a friend would
/// cause to be computed. Blurring fake bars rather than real text is the honest
/// version of this pattern — nothing sensitive is sitting in the widget tree
/// one screenshot-inspector away.
class LockedMatchCard extends StatelessWidget {
  const LockedMatchCard({super.key, required this.item, this.onUnlock});

  final LockedMatchItem item;
  final VoidCallback? onUnlock;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onUnlock != null,
      label: '${item.title} at ${item.company}. Locked match, '
          '${item.similarityPct} percent similar. Invite a friend to unlock the full analysis.',
      child: GestureDetector(
        onTap: onUnlock,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.space4),
          decoration: BoxDecoration(
            color: context.c.surface,
            border: Border.all(color: context.c.border),
            borderRadius: AppRadius.lgRadius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.company,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption.copyWith(color: context.c.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.space2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.c.accentSoft,
                      borderRadius: AppRadius.smRadius,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(AppIconName.lock, size: 12, color: context.c.accent),
                        const SizedBox(width: 4),
                        Text(
                          '${item.similarityPct}% similar',
                          style: AppTypography.caption.copyWith(
                            color: context.c.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.space3),
              // The blurred stand-in for the analysis that hasn't been run.
              ClipRRect(
                borderRadius: AppRadius.smRadius,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _placeholderBar(context, widthFactor: 0.9),
                      const SizedBox(height: 6),
                      _placeholderBar(context, widthFactor: 0.7),
                      const SizedBox(height: 6),
                      _placeholderBar(context, widthFactor: 0.45),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.space3),
              Row(
                children: [
                  AppIcon(AppIconName.lock, size: 14, color: context.c.inkFaint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Fit score and reasoning locked',
                      style: AppTypography.caption.copyWith(color: context.c.inkFaint),
                    ),
                  ),
                  if (onUnlock != null)
                    TextButton(
                      onPressed: onUnlock,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Unlock'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholderBar(BuildContext context, {required double widthFactor}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          color: context.c.border,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}
