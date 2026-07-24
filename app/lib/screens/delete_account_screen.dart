import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/hold_button.dart';

/// §4.15 — account deletion. A one-way door, so the plan gates the destructive
/// action behind a [HoldButton] (press-and-hold ~1.1s), never a plain tap, and
/// leads with a retention off-ramp ("keep my account") as the prominent choice.
///
/// On confirm it calls DELETE /account — the server cascades every
/// profile-scoped row and removes the Supabase auth user — then signs out
/// locally, which the router turns into a redirect back to /splash.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final ApiClient _apiClient = ApiClient();
  bool _deleting = false;

  Future<void> _confirmDelete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    try {
      await _apiClient.deleteAccount();
      // Success: drop the local session. The router's auth listener sees the
      // sign-out and redirects to /splash, unmounting this screen — so there's
      // no navigation to do here, and no setState after (we're on the way out).
      await Supabase.instance.client.auth.signOut();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.space6, AppSpacing.space3, AppSpacing.space6, AppSpacing.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Close (X) — cancels, same as "keep my account".
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: _deleting ? null : () => Navigator.of(context).pop(),
                  icon: AppIcon(AppIconName.x, size: 24, color: context.c.ink),
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: AppSpacing.space3),
              Text('Hey, wait!\nBefore you go…', style: AppTypography.display),
              const SizedBox(height: AppSpacing.space4),
              Text(
                'You can keep your account and come back anytime — your résumé, '
                'matches, and history stay safe until you return. Deleting is '
                'permanent and can\'t be undone.',
                style: AppTypography.body.copyWith(color: context.c.inkSoft, height: 1.55),
              ),
              const Expanded(child: Center(child: _DeletionMark())),
              // Retention off-ramp first, as the prominent (brand) action.
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _deleting ? null : () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.c.accent,
                    foregroundColor: context.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  child: const Text('Keep my account', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
              const SizedBox(height: AppSpacing.space3),
              // Destructive path — HoldButton, never a plain tap (plan §4.15).
              if (_deleting)
                Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: context.c.border),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: context.c.critical),
                  ),
                )
              else
                HoldButton(
                  idleLabel: 'Hold to delete permanently',
                  activeLabel: 'Keep holding to delete…',
                  onComplete: _confirmDelete,
                ),
              const SizedBox(height: AppSpacing.space2),
              Text(
                'Press and hold to confirm',
                textAlign: TextAlign.center,
                style: AppTypography.label.copyWith(color: context.c.inkFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet critical-tinted mark for the empty middle of the screen — enough to
/// signal "danger" without the prototype's bespoke melting-icon SVG.
class _DeletionMark extends StatelessWidget {
  const _DeletionMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      height: 132,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.c.critical.withValues(alpha: 0.1),
      ),
      child: AppIcon(AppIconName.trash, size: 56, color: context.c.critical),
    );
  }
}
