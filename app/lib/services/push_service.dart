import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import '../firebase_options.dart';
import 'api_client.dart';

/// Brick 8: initializes Firebase, requests notification permission, and
/// registers this device's FCM token with the server so the agent loop
/// (server/jobs/daily_pipeline.py) can push to it. Best-effort — every
/// step is wrapped so a push-setup failure (permission denied, no
/// profile yet, emulator with no Play Services) never blocks app
/// startup (`main()` just fires this and moves on).
class PushService {
  static final ApiClient _apiClient = ApiClient();

  static Future<void> initAndRegister() async {
    // Android-only for now (see DECISIONS.md ADR-007) — no APNs key/iOS
    // app registered in Firebase yet, and web push needs its own VAPID
    // key setup we haven't done either.
    if (kIsWeb) return;

    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('PushService: notification permission denied');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      final profile = await _apiClient.fetchCurrentProfile();
      if (profile == null) {
        // No resume uploaded yet — nothing to attach the token to. The
        // token will register on a later app start once a profile exists.
        return;
      }

      await _apiClient.registerFcmToken(token);
    } catch (e) {
      debugPrint('PushService: setup failed — $e');
    }
  }
}
