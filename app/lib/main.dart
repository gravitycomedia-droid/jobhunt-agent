import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'config/supabase_config.dart';
import 'screens/auth_gate.dart';
import 'theme/app_theme.dart';
import 'widgets/task_toast.dart';

Future<void> main() async {
  // Brick 9: Supabase must be initialized before AuthGate reads
  // currentSession or listens to onAuthStateChange, so this has to
  // complete before runApp — unlike PushService's Firebase init (fired
  // from AuthGate after sign-in instead), auth is on the critical path to
  // first paint since every screen depends on knowing sign-in state.
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: SupabaseConfig.url, anonKey: SupabaseConfig.anonKey);
  runApp(const JobHuntAgentApp());
}

/// The app's root widget. FlutterFlow builds this for you behind the scenes
/// (the "App Settings" theme + the page you set as your start page); here
/// it's one small StatelessWidget — stateless because this widget itself
/// never changes after being built, unlike HomeScreen below it.
class JobHuntAgentApp extends StatelessWidget {
  const JobHuntAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Job-Hunt Agent',
      theme: AppTheme.light,
      // Phase 2: TaskCenter's completion toasts fire through this global
      // key so they show on whatever screen/tab the user is on when a
      // background task finishes.
      scaffoldMessengerKey: appScaffoldMessengerKey,
      home: const AuthGate(),
    );
  }
}
