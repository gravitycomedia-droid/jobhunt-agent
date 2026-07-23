import 'package:flutter/services.dart';

import 'cache_service.dart';

/// Phase 2d: the single wrapper over [HapticFeedback]. Every haptic in the app
/// goes through here so there's one on/off switch and one policy.
///
/// Policy (doc 18 §2d): only **discrete** events fire — tab switch, chip/filter
/// toggle, hold-button start/complete, Kanban pickup/drop, celebration,
/// guardrail flag, background-task done, error. **Nothing on loading, nothing
/// on scroll, nothing repeating.** Flutter has no continuous/waveform haptic
/// without platform channels, and Android quality varies wildly by device, so
/// discrete events are the only thing that feels consistent.
///
/// [enabled] is a persisted user setting (default on); the OS still applies its
/// own system-level haptic setting on top of every call.
class HapticService {
  HapticService._();
  static final HapticService instance = HapticService._();

  bool _enabled = true;
  bool get enabled => _enabled;

  /// Restore the persisted preference. Safe to call before `runApp`.
  Future<void> load() async {
    _enabled = await CacheService.instance.readHapticsEnabled() ?? true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await CacheService.instance.writeHapticsEnabled(value);
  }

  /// Tab switch, chip/filter toggle, Kanban drop.
  void selection() {
    if (_enabled) HapticFeedback.selectionClick();
  }

  /// Hold-button start, Kanban pickup, background-task done, guardrail flag.
  void light() {
    if (_enabled) HapticFeedback.lightImpact();
  }

  /// Hold-button complete, error.
  void medium() {
    if (_enabled) HapticFeedback.mediumImpact();
  }

  /// Celebration (fired once).
  void heavy() {
    if (_enabled) HapticFeedback.heavyImpact();
  }
}
