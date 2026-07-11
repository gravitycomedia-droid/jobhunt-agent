import 'package:flutter/material.dart';

import '../widgets/app_shell.dart';
import 'applications_body.dart';
import 'home_body.dart';
import 'jobs_list_body.dart';
import 'matches_body.dart';
import 'profile_body.dart';

const List<String> _tabOrder = ['home', 'jobs', 'matches', 'applications', 'profile'];

/// Brick 9 polish: the signed-in app shell — one [AppShell] with a 5-tab
/// bottom nav. [IndexedStack] keeps all five tab bodies alive across
/// switches so scroll position and loaded data survive tapping away and
/// back, instead of refetching from scratch every time.
///
/// Phase 3A: the old branded "Job Hunt Agent" title bar is gone
/// (`showHeader: false`) — each tab body owns its own [PageHeader] with
/// contextual actions instead (Home keeps its greeting row; the
/// run-agent-now trigger moved there with it).
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  String _active = 'home';

  @override
  Widget build(BuildContext context) {
    final index = _tabOrder.indexOf(_active);
    return AppShell(
      active: _active,
      showHeader: false,
      onNavigate: (key) => setState(() => _active = key),
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
