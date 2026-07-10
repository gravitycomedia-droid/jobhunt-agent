import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/task_center.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_shell.dart';
import '../widgets/background_task_dialog.dart';
import 'applications_body.dart';
import 'home_body.dart';
import 'jobs_list_body.dart';
import 'matches_body.dart';
import 'profile_body.dart';

const List<String> _tabOrder = ['home', 'jobs', 'matches', 'applications', 'profile'];
const Map<String, String> _tabTitles = {
  'home': 'Job-Hunt Agent',
  'jobs': 'Jobs',
  'matches': 'Matches',
  'applications': 'Application Tracker',
  'profile': 'Profile',
};

/// Brick 9 polish: the signed-in app shell — one [AppShell] with a 5-tab
/// bottom nav (previously designed in the "Job-Hunt Agent design system"
/// reference but never wired up; every screen used to be reached by
/// pushing from [HomeScreen]'s AppBar icons instead). [IndexedStack] keeps
/// all five tab bodies alive across switches so scroll position and
/// loaded data survive tapping away and back, instead of refetching from
/// scratch every time.
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  final ApiClient _apiClient = ApiClient();

  String _active = 'home';

  // ADR-010: the pipeline runs server-side as a background task; the
  // TaskCenter poller survives tab switches, so this screen only listens
  // for progress (spinner on the trailing icon) and completion (snackbar).
  ValueNotifier<TrackedTask?> get _pipelineTask => TaskCenter.instance.notifierFor(TaskKind.pipeline);
  bool get _isRunningPipeline => _pipelineTask.value?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _pipelineTask.addListener(_onPipelineChanged);
  }

  @override
  void dispose() {
    _pipelineTask.removeListener(_onPipelineChanged);
    super.dispose();
  }

  void _onPipelineChanged() {
    // Completion/failure toasts come from TaskCenter's global toast (Phase
    // 2) — this listener only keeps the trailing icon's spinner honest.
    if (mounted) setState(() {});
  }

  /// Manual trigger for the agent loop, scoped to this user only (Brick 9:
  /// POST /pipeline/run-mine) — same per-user work the Render cron's
  /// all-users POST /pipeline/run does for everyone, useful here since no
  /// cron is deployed yet. Lives on the Home tab's trailing slot since
  /// it's a global action, not scoped to any one tab's data.
  Future<void> _runPipeline() async {
    unawaited(showBackgroundTaskDialog(
      context,
      'Agent run started',
      'Fetching fresh jobs and scoring them against your profile. This runs '
          'in the background and usually takes 2–3 minutes — keep using the '
          "app, we'll notify you when it's done.",
    ));
    await TaskCenter.instance.start(TaskKind.pipeline, () => _apiClient.runPipeline());
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabOrder.indexOf(_active);
    return AppShell(
      active: _active,
      title: _tabTitles[_active],
      onNavigate: (key) => setState(() => _active = key),
      trailing: _active == 'home'
          ? IconButton(
              tooltip: 'Run agent now',
              icon: _isRunningPipeline
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brand))
                  : const AppIcon(AppIconName.bot),
              onPressed: _isRunningPipeline ? null : _runPipeline,
            )
          : null,
      child: IndexedStack(
        index: index,
        children: [
          HomeBody(onNavigateToTab: (key) => setState(() => _active = key)),
          const JobsListBody(),
          const MatchesBody(),
          const ApplicationsBody(),
          const ProfileBody(),
        ],
      ),
    );
  }
}
