import 'package:flutter/foundation.dart' show kIsWeb;

/// Brick 9: Supabase project coordinates for client-side auth only — the
/// app never queries Supabase tables directly (Golden Rule 1: it only
/// ever talks to our FastAPI server). The anon key is safe to embed here;
/// it's designed to be public and is meaningless without RLS on the server
/// side, same as a Firebase client config. Mirrors server/.env's
/// SUPABASE_URL / SUPABASE_ANON_KEY — keep the two in sync by hand.
class SupabaseConfig {
  static const String url = 'https://mlraykxgariyvxlmlmxv.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1scmF5a3hnYXJpeXZ4bG1sbXh2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0OTk4MjUsImV4cCI6MjA5OTA3NTgyNX0.WIAe8hDR6IB_CfhspInZzXvMqT5uMiyxjHnN7cSoTkY';

  /// Where Supabase's OAuth flow returns after Google sign-in — platform
  /// dependent, which is why this is a getter, not a const:
  ///
  /// - **Web** (local verification builds): back to this page's own origin
  ///   (e.g. `http://localhost:5757`). Sending the Android deep link from a
  ///   browser gives GoTrue an un-openable target and surfaces as its raw
  ///   `unexpected_failure` JSON instead of returning to the app. The
  ///   origin must be in Supabase's Additional Redirect URLs.
  /// - **Android**: the custom URL scheme (matches applicationId in
  ///   android/app/build.gradle.kts); AndroidManifest.xml declares the
  ///   matching intent-filter so the OS routes it back into the app.
  static String get redirectUrl {
    if (kIsWeb) return Uri.base.origin;
    return 'com.jobhuntagent.jobhunt_agent://login-callback/';
  }
}
