import 'package:flutter/material.dart';

import '../models/background_task.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/agent_orb.dart';
import '../widgets/agent_overlay.dart';
import '../widgets/agent_toast.dart';
import '../widgets/celebration_modal.dart';
import '../widgets/fit_gauge.dart';
import '../widgets/hatched_progress.dart';
import '../widgets/hold_button.dart';
import '../widgets/mascot_loader.dart';
import '../widgets/source_chip.dart';

/// Phase 3 — debug-only gallery of the signature widget library.
///
/// Registered at `/debug/gallery` behind `kDebugMode` (see app_router.dart).
/// A local light/dark toggle wraps the body in the opposite [ThemeData] so
/// every widget can be proofed in **both themes** without touching the app's
/// global mode — the Phase 3 acceptance gate.
class DebugGalleryScreen extends StatefulWidget {
  const DebugGalleryScreen({super.key});

  @override
  State<DebugGalleryScreen> createState() => _DebugGalleryScreenState();
}

class _DebugGalleryScreenState extends State<DebugGalleryScreen> {
  bool _dark = false;
  int _gaugeKey = 0; // bump to replay the gauge reveal

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _dark ? appDark : appLight,
      child: Builder(
        builder: (context) {
          final c = context.c;
          return Scaffold(
            backgroundColor: c.paper,
            appBar: AppBar(
              backgroundColor: c.surface,
              foregroundColor: c.ink,
              title: const Text('Widget Gallery'),
              actions: [
                Row(
                  children: [
                    Icon(Icons.light_mode, size: 18, color: c.inkSoft),
                    Switch(value: _dark, onChanged: (v) => setState(() => _dark = v)),
                    Icon(Icons.dark_mode, size: 18, color: c.inkSoft),
                    const SizedBox(width: 8),
                  ],
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              children: [
                _section(c, 'FitGauge', [
                  Center(child: FitGauge(key: ValueKey(_gaugeKey), target: 92, delta: 4)),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: () => setState(() => _gaugeKey++),
                      child: const Text('Replay reveal'),
                    ),
                  ),
                ]),
                _section(c, 'AgentMascot', const [
                  Center(child: AgentMascot(size: 96)),
                ]),
                _section(c, 'AgentOrb', const [
                  Center(child: AgentOrb(size: 120)),
                ]),
                _section(c, 'HoldButton', [
                  HoldButton(
                    idleLabel: 'Hold to submit',
                    onComplete: () => showAgentToast(success: true, message: 'Submitted'),
                  ),
                ]),
                _section(c, 'SourceChip (11 known + fallbacks)', [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: const [
                      'linkedin', 'indeed', 'naukri', 'internshala', 'unstop',
                      'adzuna', 'jsearch', 'greenhouse', 'lever', 'google_form',
                      'manual', 'some_new_board', '', // last two exercise the fallback
                    ].map((s) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SourceChip(source: s, size: 32),
                            const SizedBox(height: 4),
                            Text(s.isEmpty ? '(empty)' : s, style: mono(9, color: c.inkFaint)),
                          ],
                        )).toList(),
                  ),
                ]),
                _section(c, 'HatchedProgress', [
                  const HatchedProgress(value: 0.3),
                  const SizedBox(height: 10),
                  const HatchedProgress(value: 0.7),
                  const SizedBox(height: 10),
                  const HatchedProgress(value: 1.0),
                ]),
                _section(c, 'MascotLoader', const [
                  SizedBox(height: 160, child: MascotLoader(caption: 'Re-ranking matches…')),
                ]),
                _section(c, 'AgentToast', const [
                  AgentToastContent(success: true, message: 'Re-rank complete — 8 new, 12 skipped'),
                  SizedBox(height: 10),
                  AgentToastContent(success: false, message: 'Job refresh failed'),
                ]),
                _section(c, 'AgentOverlay', [
                  SizedBox(
                    height: 260,
                    child: AgentOverlay(
                      task: const BackgroundTask(id: '1', taskType: 'rerank', status: 'running'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 220,
                    child: AgentOverlay(
                      task: const BackgroundTask(id: '2', taskType: 'rerank', status: 'failed', error: 'Timed out'),
                      onRetry: () {},
                    ),
                  ),
                ]),
                _section(c, 'CelebrationModal', [
                  FilledButton(
                    onPressed: () => showCelebration(context),
                    child: const Text('Fire celebration'),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _section(AppColors c, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 12),
          child: Text(title, style: mono(13, w: FontWeight.w700, color: c.accent)),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ],
    );
  }
}
