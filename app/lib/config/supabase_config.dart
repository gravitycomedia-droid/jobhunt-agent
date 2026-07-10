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

  /// The Android app's custom URL scheme (matches applicationId in
  /// android/app/build.gradle.kts) — Supabase's OAuth flow redirects here
  /// after Google sign-in completes in the browser, and AndroidManifest.xml
  /// must declare a matching intent-filter for the OS to route it back in.
  static const String redirectUrl = 'com.jobhuntagent.jobhunt_agent://login-callback/';
}
