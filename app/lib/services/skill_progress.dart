import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

/// Which skill-growth recommendations the user has ticked off.
///
/// Device-local by design: this is a personal checklist over the agent's
/// suggestions, not agent state — nothing on the server reads it, and no
/// scoring, matching or résumé output depends on it. Keeping it out of the
/// profile row means a re-rank that changes the recommendations can't leave
/// orphaned server rows behind.
///
/// Namespaced by the signed-in user's id, exactly like [CacheService], so
/// switching accounts on one device can never show the previous user's ticks.
class SkillProgressStore {
  SkillProgressStore._();
  static final SkillProgressStore instance = SkillProgressStore._();

  static const _key = 'skill_progress';

  String? get _userId => Supabase.instance.client.auth.currentUser?.id;

  /// The ids of every completed item. Ids are content-derived (see
  /// `SkillGrowthScreen`'s `_id`), so they stay stable across reloads while a
  /// recommendation keeps its text, and simply stop matching when the agent
  /// replaces it — a stale tick disappears instead of attaching to the wrong
  /// row.
  Future<Set<String>> read() async {
    final userId = _userId;
    if (userId == null) return {};
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('$userId:$_key') ?? const []).toSet();
  }

  Future<void> write(Set<String> done) async {
    final userId = _userId;
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$userId:$_key', done.toList());
  }
}
