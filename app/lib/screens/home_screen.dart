import 'package:flutter/material.dart';

import '../models/health_status.dart';
import '../services/api_client.dart';

/// FlutterFlow analogy: this is one Page. Everything Flutter renders is a
/// Widget, and widgets nest inside widgets — the "widget tree". Scaffold is
/// the page frame (app bar + body, like FlutterFlow's Page Scaffold), Center
/// lays out one child in the middle, Column stacks children vertically — same
/// mental model as FlutterFlow's Column/Row, just written instead of dragged.
///
/// This is a StatefulWidget (not Stateless) because the screen needs to
/// remember something that changes over time: whether we're loading, got
/// data, or hit an error. Stateless widgets can't hold that memory.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  HealthStatus? _health;

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  Future<void> _loadHealth() async {
    // `setState` is how you tell Flutter "some state changed, please
    // re-render." Nothing on screen updates just because a variable changed
    // — Flutter only rebuilds the widget tree when setState runs. This is
    // the one Dart idiom with no FlutterFlow equivalent: FlutterFlow's
    // builder updates the UI for you automatically after an action; here,
    // you ask for it explicitly.
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final health = await _apiClient.fetchHealth();
      setState(() {
        _health = health;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Job-Hunt Agent')),
      body: Center(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }

    if (_errorMessage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Could not reach the server:\n$_errorMessage',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _loadHealth, child: const Text('Retry')),
        ],
      );
    }

    // The `!` below is a null-assertion: it tells Dart "trust me, this is
    // not null right now." We can only reach this branch once _isLoading is
    // false and _errorMessage is null, which only happens after _health was
    // set — so it's safe here, even though the field's type is `HealthStatus?`
    // (nullable) everywhere else.
    final health = _health!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 48),
        const SizedBox(height: 12),
        Text('Server status: ${health.status}'),
        Text('As of: ${health.time}'),
      ],
    );
  }
}
