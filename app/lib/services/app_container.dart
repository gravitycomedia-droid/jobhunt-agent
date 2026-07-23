import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Phase 2c: the app's single Riverpod [ProviderContainer].
///
/// Widgets get their `ref` from the [UncontrolledProviderScope] wrapping the
/// app (see main.dart) which is bound to THIS container, so widget reads and
/// non-widget reads (e.g. AppRouterNotifier's sign-out reset, which has no
/// BuildContext) all hit the same provider state.
final ProviderContainer appContainer = ProviderContainer();
