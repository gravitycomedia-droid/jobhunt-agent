import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// Shared zero-data pattern for Jobs, Shortlist, Matches, Applications,
/// and the Activity Log. Icon medallion + title + message + optional
/// primary action.
///
/// ```dart
/// EmptyState(
///   icon: AppIconName.briefcase,
///   title: 'No jobs yet',
///   message: 'Pull to refresh to fetch today\'s postings.',
/// )
/// ```
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = AppIconName.search,
    this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final AppIconName icon;
  final String? title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space6, vertical: AppSpacing.space16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
            child: AppIcon(icon, size: 28, color: AppColors.brand600),
          ),
          const SizedBox(height: AppSpacing.space4),
          if (title != null)
            Text(title!, style: AppTypography.headingSm, textAlign: TextAlign.center),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.space5),
              child: ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 0), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10)),
                child: Text(actionLabel!),
              ),
            ),
        ],
      ),
    );
  }
}
