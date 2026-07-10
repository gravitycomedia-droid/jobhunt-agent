import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Compact card for one lane of the Applications Kanban board (Brick 7).
/// Deliberately smaller than [JobCard]/[MatchCard] — it lives inside a
/// narrow, vertically-scrolling [KanbanColumn], not a full-width list.
/// Tapping opens the stage picker via [onTap].
///
/// ```dart
/// ApplicationCard(
///   title: 'Senior Product Designer',
///   company: 'Northwind',
///   onTap: () => showStagePicker(...),
/// )
/// ```
class ApplicationCard extends StatelessWidget {
  const ApplicationCard({
    super.key,
    required this.title,
    required this.company,
    this.salary,
    this.onTap,
  });

  final String title;
  final String company;
  final String? salary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: AppRadius.mdRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdRadius,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: AppRadius.mdRadius,
          ),
          padding: const EdgeInsets.all(AppSpacing.space3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                company,
                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (salary != null) ...[
                const SizedBox(height: 6),
                Text(
                  salary!,
                  style: TextStyle(
                    fontFamily: AppTypography.monoData.fontFamily,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
