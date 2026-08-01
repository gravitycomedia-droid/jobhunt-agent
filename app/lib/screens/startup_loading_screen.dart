import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../router/app_router.dart' show appRouterNotifier;
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_loader.dart';
import '../widgets/brand_mark.dart';

/// What the app shows while the routing decision is still being made (the
/// `/loading` route): signed in, but we don't yet know whether to land on Home
/// or on onboarding.
///
/// This used to be a bare `Scaffold(body: Center(AppLoader()))`. On `paper`
/// (#FAFAF9) with one small mark in the middle that is, to a user, an **almost
/// white blank screen** — and because the profile call had no timeout, a
/// waking radio or a cold Cloud Run instance could hold it there for a minute
/// or more. That is what "the app went white" was.
///
/// So this screen: says what it's doing, and after [_slowAfter] admits it's
/// slow and offers a way out. A wait the user can see and escape is not a
/// blank screen.
class StartupLoadingScreen extends StatefulWidget {
  const StartupLoadingScreen({super.key});

  @override
  State<StartupLoadingScreen> createState() => _StartupLoadingScreenState();
}

class _StartupLoadingScreenState extends State<StartupLoadingScreen> {
  static const _slowAfter = Duration(seconds: 8);

  bool _slow = false;
  bool _retrying = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_slowAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await appRouterNotifier.refreshOnResume();
    if (mounted) setState(() => _retrying = false);
  }

  Future<void> _signOut() async {
    // Last resort when the session itself is the problem — the redirect takes
    // the user to the splash/sign-in screen from here.
    await Supabase.instance.client.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The mark draws on a transparent ground, so colour it for the
                // paper background here (it defaults to white for brand fills).
                BrandMark(size: 56, color: c.accent),
                const SizedBox(height: AppSpacing.space6),
                const AppLoader(),
                const SizedBox(height: AppSpacing.space5),
                Text(
                  _slow ? 'Still getting things ready…' : 'Getting things ready…',
                  style: AppTypography.title,
                  textAlign: TextAlign.center,
                ),
                if (_slow) ...[
                  const SizedBox(height: 8),
                  Text(
                    'The server may be waking up. Your data is safe — this only '
                    'affects what we show first.',
                    style: AppTypography.bodySm.copyWith(color: c.inkSoft, height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.space5),
                  FilledButton(
                    onPressed: _retrying ? null : _retry,
                    child: Text(_retrying ? 'Retrying…' : 'Try again'),
                  ),
                  TextButton(onPressed: _signOut, child: const Text('Sign in again')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
