import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_shell.dart';
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
  bool _isRunningPipeline = false;

  /// Manual trigger for the agent loop, scoped to this user only (Brick 9:
  /// POST /pipeline/run-mine) — same per-user work the Render cron's
  /// all-users POST /pipeline/run does for everyone, useful here since no
  /// cron is deployed yet. Lives on the Home tab's trailing slot since
  /// it's a global action, not scoped to any one tab's data.
  Future<void> _runPipeline() async {
    setState(() => _isRunningPipeline = true);
    try {
      await _apiClient.runPipeline();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent run complete — check Matches and Track for updates.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Agent run failed: $e')));
    } finally {
      if (mounted) setState(() => _isRunningPipeline = false);
    }
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
