import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'config/supabase_config.dart';
import 'screens/auth_gate.dart';
import 'services/api_client.dart';
import 'services/theme_controller.dart';
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
  // Phase 2: restore the persisted light/dark/system choice before first paint
  // so there's no theme flash on launch.
  await ThemeController.instance.load();
  // ADR-010: Render free tier spins the server down after ~15min idle and
  // takes 30-60s to cold-start. Not awaiting this means the wake-up ping
  // happens during app launch instead of during the user's first
  // re-rank/tailor tap, where it used to blow past a 30s client timeout.
  // Doesn't eliminate the cold start, just moves it earlier. Errors are
  // expected and ignored — this is a best-effort nudge, not a real call.
  _warmUpServer();
  runApp(const JobHuntAgentApp());
}

void _warmUpServer() {
  ApiClient().fetchHealth().ignore();
}

/// The app's root widget. FlutterFlow builds this for you behind the scenes
/// (the "App Settings" theme + the page you set as your start page); here
/// it's one small StatelessWidget — stateless because this widget itself
/// never changes after being built, unlike HomeScreen below it.
class JobHuntAgentApp extends StatelessWidget {
  const JobHuntAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Phase 2: rebuild the MaterialApp whenever the theme mode changes so the
    // Profile/Settings toggle takes effect live. `ValueListenableBuilder` is
    // the FlutterFlow-equivalent of binding a widget to an App State field.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'FirstRole',
        theme: appLight,
        darkTheme: appDark,
        themeMode: mode,
        // TaskCenter's completion toasts fire through this global key so they
        // show on whatever screen/tab the user is on when a background task
        // finishes.
        scaffoldMessengerKey: appScaffoldMessengerKey,
        home: const AuthGate(),
      ),
    );
  }
}
