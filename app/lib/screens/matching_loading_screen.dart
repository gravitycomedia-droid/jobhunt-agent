import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/task_center.dart';
import '../theme/app_tokens.dart';

/// Onboarding step 5 (frontend rebuild Phase 1, prototype `ui.isMatching`):
/// the transitional screen between submitting target roles and landing on
/// the main tab shell. Fires the same refresh+rerank [ApiClient] calls the
/// "Run agent now" button uses, but — like [MatchesBody] already learned
/// the hard way — a cold rerank of the default 20-job batch can take 7+
/// minutes (one sequential Gemini call per job), so this does NOT await
/// either call. It kicks them off in the background and hands off to
/// [MainTabScreen] after a short, fixed display time; [HomeBody] and
/// [MatchesBody] already know how to show cached-then-refreshing state on
/// their own once they mount.
class MatchingLoadingScreen extends StatefulWidget {
  const MatchingLoadingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<MatchingLoadingScreen> createState() => _MatchingLoadingScreenState();
}

class _MatchingLoadingScreenState extends State<MatchingLoadingScreen> {
  final ApiClient _apiClient = ApiClient();

  @override
  void initState() {
    super.initState();
    // ADR-010: refresh first, then start the rerank as a tracked background
    // task — TaskCenter keeps polling after this screen hands off, so
    // MatchesBody refreshes itself when scoring completes.
    unawaited(
      _apiClient
          .refreshJobs()
          .catchError((_) => <String, dynamic>{}) // rerank still works against the existing pool
          .then((_) => TaskCenter.instance.start(TaskKind.rerank, () => _apiClient.rerankShortlist(limit: 20))),
    );
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 132,
                height: 132,
                child: CircularProgressIndicator(strokeWidth: 8, color: AppColors.brand600),
              ),
              const SizedBox(height: AppSpacing.space5),
              Text('Finding your matches', style: AppTypography.title),
              const SizedBox(height: 6),
              Text(
                'Refreshing postings and scoring them against your profile — this continues in the background.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
