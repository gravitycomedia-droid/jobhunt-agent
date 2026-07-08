import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
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
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const HomeScreen(),
    );
  }
}
