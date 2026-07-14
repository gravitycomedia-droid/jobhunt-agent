import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, GoTrueClientSignInProvider, LaunchMode, OAuthProvider, Supabase;

import '../config/supabase_config.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_form_field.dart';

/// Onboarding step 1b (frontend rebuild Phase 1, prototype `ui.isAuth`):
/// shown after Splash. Two providers:
/// - Email/password via Supabase's own `signInWithPassword`/`signUp` — no
///   server change needed, since server/services/auth.py verifies any
///   valid Supabase session token regardless of how it was issued.
/// - Google via `signInWithOAuth` (unchanged from the prior Brick 9
///   Google-only LoginScreen — see DECISIONS.md ADR-008), which hands off
///   to the browser and lets [AuthGate]'s session listener pick up the
///   resulting session; nothing else to do here once that fires.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.startInSignUp = false, this.onBack});

  final bool startInSignUp;
  final VoidCallback? onBack;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late bool _isSignUp = widget.startInSignUp;
  bool _isSubmitting = false;
  String? _errorMessage;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitPassword() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      if (_isSignUp) {
        final res = await Supabase.instance.client.auth.signUp(email: email, password: password);

        // An existing user who lands on Sign up must be told to sign in instead.
        // Supabase makes that harder than it sounds: when "Confirm email" is ON it
        // does NOT raise an error for a duplicate signup — that would leak which
        // emails have accounts — and instead returns a decoy user with an EMPTY
        // `identities` list and no session. Without this check the form looks like
        // it succeeded and then simply never signs the user in.
        // (With "Confirm email" OFF, Supabase *does* throw — handled in the catch.)
        final identities = res.user?.identities;
        if (identities != null && identities.isEmpty) {
          if (!mounted) return;
          setState(() {
            _errorMessage = 'That email already has an account. Sign in instead.';
            _isSignUp = false; // flip to sign-in; the typed email is kept
          });
          return;
        }

        // Signed up, but the account needs email confirmation before a session exists.
        if (res.session == null) {
          if (!mounted) return;
          setState(() => _errorMessage = 'Check your inbox to confirm your email, then sign in.');
          return;
        }
      } else {
        await Supabase.instance.client.auth.signInWithPassword(email: email, password: password);
      }
      // AuthGate's session listener takes it from here once the session lands.
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _friendlyAuthMessage(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Turns Supabase's raw auth errors into something a user can act on.
  ///
  /// Side effect: a duplicate signup also flips the form to sign-in, so the fix
  /// is one tap away rather than something the user has to work out.
  String _friendlyAuthMessage(AuthException e) {
    final raw = e.message.toLowerCase();

    if (raw.contains('already registered') || raw.contains('already exists')) {
      _isSignUp = false; // caller is inside setState
      return 'That email already has an account. Sign in instead.';
    }
    if (raw.contains('invalid login credentials')) {
      return 'Wrong email or password. If you signed up with Google, use "Continue with Google".';
    }
    if (raw.contains('email not confirmed')) {
      return 'Confirm your email first — check your inbox for the link.';
    }
    return e.message;
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      // Phase 1B: on Android, externalApplication forces a real browser
      // (not an in-app custom tab some OEMs break) so the
      // com.jobhuntagent.firstrole:// deep link reliably routes back
      // into the app. On web, platformDefault navigates THIS tab to Google
      // and back — a new tab would leave the original page waiting forever.
      // The Supabase project's URL Configuration must allow-list
      // SupabaseConfig.redirectUrl (deep link AND the local web origin) —
      // see MANUAL_STEPS.md — otherwise Supabase falls back to Site URL.
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: SupabaseConfig.redirectUrl,
        authScreenLaunchMode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.onBack != null)
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
              const SizedBox(height: AppSpacing.space3),
              Text(_isSignUp ? 'Create your account' : 'Welcome back', style: AppTypography.headingSm),
              const SizedBox(height: 6),
              Text(
                _isSignUp ? 'Set up your job-search agent in a minute.' : 'Sign in to keep hunting.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space6),
              AppFormField(
                label: 'Email',
                controller: _emailController,
                placeholder: 'you@email.com',
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: AppSpacing.space3),
              AppFormField(
                label: 'Password',
                controller: _passwordController,
                placeholder: '••••••••',
                obscureText: true,
              ),
              const SizedBox(height: AppSpacing.space5),
              if (_errorMessage != null) ...[
                Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: AppColors.criticalText)),
                const SizedBox(height: AppSpacing.space3),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitPassword,
                  child: Text(_isSubmitting ? 'Please wait…' : (_isSignUp ? 'Create account' : 'Sign in')),
                ),
              ),
              const SizedBox(height: AppSpacing.space5),
              Row(
                children: [
                  const Expanded(child: Divider(color: AppColors.border)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('or', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
                  ),
                  const Expanded(child: Divider(color: AppColors.border)),
                ],
              ),
              const SizedBox(height: AppSpacing.space5),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isSubmitting ? null : _signInWithGoogle,
                  child: const Text('Continue with Google'),
                ),
              ),
              const Spacer(),
              Center(
                child: TextButton(
                  onPressed: _isSubmitting ? null : () => setState(() => _isSignUp = !_isSignUp),
                  child: Text(_isSignUp ? 'Already have an account? Sign in' : "Don't have an account? Sign up"),
                ),
              ),
              const SizedBox(height: AppSpacing.space4),
            ],
          ),
        ),
      ),
    );
  }
}
