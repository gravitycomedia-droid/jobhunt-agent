import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Phase 2: one ScaffoldMessenger for the whole app, attached to
/// [MaterialApp.scaffoldMessengerKey] in main.dart. Completion toasts fire
/// from TaskCenter (a service with no BuildContext), and must land on
/// whatever screen the user is on now — not the tab that started the task.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Console/status-line style completion toast (Phase 2): monospace text,
/// "✓ Re-rank complete — 8 new, 12 skipped" / "✗ Job refresh failed" with
/// an optional Retry action. Floating so it clears the bottom nav.
void showTaskToast({required bool success, required String message, VoidCallback? onRetry}) {
  final messenger = appScaffoldMessengerKey.currentState;
  if (messenger == null) return; // app not mounted yet — nothing to show on

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: success ? AppColors.successSoft : AppColors.criticalSoft,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdRadius,
        side: BorderSide(color: success ? AppColors.successText : AppColors.criticalText, width: 1),
      ),
      duration: Duration(seconds: success ? 4 : 8),
      content: Text(
        '${success ? '✓' : '✗'} $message',
        style: AppTypography.monoData.copyWith(
          fontSize: 13,
          color: success ? AppColors.successText : AppColors.criticalText,
        ),
      ),
      action: onRetry == null
          ? null
          : SnackBarAction(
              label: 'Retry',
              textColor: AppColors.criticalText,
              onPressed: onRetry,
            ),
    ),
  );
}
