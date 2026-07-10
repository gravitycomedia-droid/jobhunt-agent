import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, GoTrueClientSignInProvider, OAuthProvider, Supabase;

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
        await Supabase.instance.client.auth.signUp(email: email, password: password);
      } else {
        await Supabase.instance.client.auth.signInWithPassword(email: email, password: password);
      }
      // AuthGate's session listener takes it from here once the session lands.
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

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: SupabaseConfig.redirectUrl,
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
