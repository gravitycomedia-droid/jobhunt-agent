import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../widgets/brand_mark.dart';

/// Onboarding step 1 (frontend rebuild Phase 1, prototype `ui.isSplash`):
/// the brand cover shown before a session exists. [onGetStarted] and
/// [onSignIn] both lead to the same [AuthScreen] — the prototype
/// distinguishes them only to pre-select the sign-up vs sign-in tab.
///
/// Brick 10: the content now animates in as a staggered cascade (mark →
/// wordmark → tagline → buttons) rather than appearing all at once. It is one
/// [AnimationController] with [Interval]s rather than four controllers, so the
/// beats can't drift apart. Under the OS "reduce motion" setting the whole
/// thing snaps straight to its resting state.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onGetStarted, required this.onSignIn});

  final VoidCallback onGetStarted;
  final VoidCallback onSignIn;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery isn't available in initState, and we need it to decide whether
    // to animate at all. Guard so this only fires once.
    if (_started) return;
    _started = true;

    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1; // straight to rest, no motion
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brand600,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.space6,
            AppSpacing.space8,
            AppSpacing.space6,
            AppSpacing.space6,
          ),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // The mark also scales up slightly, which reads as it
                    // "arriving" rather than merely fading in.
                    _Entrance(
                      controller: _controller,
                      begin: 0.0,
                      end: 0.55,
                      scaleFrom: 0.82,
                      child: Container(
                        width: 92,
                        height: 92,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: AppRadius.xlRadius,
                        ),
                        child: const BrandMark(size: 50, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    _Entrance(
                      controller: _controller,
                      begin: 0.18,
                      end: 0.68,
                      child: RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: const TextStyle(
                            fontSize: 33,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: Colors.white,
                          ),
                          children: [
                            const TextSpan(text: 'First'),
                            TextSpan(
                              text: 'Role',
                              style: TextStyle(
                                fontWeight: FontWeight.w400,
                                color: Colors.white.withValues(alpha: 0.82),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _Entrance(
                      controller: _controller,
                      begin: 0.32,
                      end: 0.82,
                      child: Text(
                        'Your AI agent for fresher & intern roles — from resume to signed offer.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: Colors.white.withValues(alpha: 0.86),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _Entrance(
                controller: _controller,
                begin: 0.46,
                end: 1.0,
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: widget.onGetStarted,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.brand700,
                        ),
                        child: const Text('Get started'),
                      ),
                    ),
                    const SizedBox(height: 11),
                    TextButton(
                      onPressed: widget.onSignIn,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.92),
                      ),
                      child: const Text('I already have an account'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades a child in while lifting it a few pixels, over [begin]..[end] of the
/// parent controller's timeline. Optionally scales it up from [scaleFrom].
///
/// Dart note: `Animation<double>` values are read inside [AnimatedBuilder], so
/// only this subtree rebuilds per frame — not the whole screen.
class _Entrance extends StatelessWidget {
  const _Entrance({
    required this.controller,
    required this.begin,
    required this.end,
    required this.child,
    this.scaleFrom,
  });

  final AnimationController controller;
  final double begin;
  final double end;
  final Widget child;
  final double? scaleFrom;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: controller,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );

    return AnimatedBuilder(
      animation: curve,
      builder: (context, inner) {
        final t = curve.value;
        Widget out = Opacity(
          opacity: t,
          // Lift from 14px below its resting position.
          child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: inner),
        );
        if (scaleFrom != null) {
          out = Transform.scale(scale: scaleFrom! + (1 - scaleFrom!) * t, child: out);
        }
        return out;
      },
      child: child,
    );
  }
}
