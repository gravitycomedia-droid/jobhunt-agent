import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// Which semantic system a [StatusPill] represents.
enum PillContext { verdict, guardrail, stage }

enum _Tone { success, warning, critical, info, neutral }

class _ToneColors {
  const _ToneColors(this.bg, this.fg, this.border, this.dot);
  final Color bg;
  final Color fg;
  final Color border;
  final Color dot;
}

const Map<_Tone, _ToneColors> _toneMap = {
  _Tone.success: _ToneColors(
    AppColors.successSoft,
    AppColors.successText,
    AppColors.successBorder,
    AppColors.successFill,
  ),
  _Tone.warning: _ToneColors(
    AppColors.warningSoft,
    AppColors.warningText,
    AppColors.warningBorder,
    AppColors.warningFill,
  ),
  _Tone.critical: _ToneColors(
    AppColors.criticalSoft,
    AppColors.criticalText,
    AppColors.criticalBorder,
    AppColors.criticalFill,
  ),
  _Tone.info: _ToneColors(AppColors.infoSoft, AppColors.infoText, AppColors.infoBorder, AppColors.infoFill),
  _Tone.neutral: _ToneColors(
    AppColors.neutralSoft,
    AppColors.neutralText,
    AppColors.neutralChipBorder,
    AppColors.neutralFill,
  ),
};

class _PillSpec {
  const _PillSpec(this.tone, this.label, [this.icon]);
  final _Tone tone;
  final String label;
  final AppIconName? icon;
}

const Map<String, _PillSpec> _verdictMap = {
  'apply': _PillSpec(_Tone.success, 'Apply', AppIconName.check),
  'stretch': _PillSpec(_Tone.warning, 'Stretch', AppIconName.arrowUpRight),
  'skip': _PillSpec(_Tone.critical, 'Skip', AppIconName.x),
};

const Map<String, _PillSpec> _guardrailMap = {
  'pass': _PillSpec(_Tone.success, 'Guardrail pass', AppIconName.check),
  'fail': _PillSpec(_Tone.critical, 'Guardrail fail', AppIconName.alertTriangle),
};

const Map<String, _PillSpec> _stageMap = {
  'new': _PillSpec(_Tone.neutral, 'New'),
  'saved': _PillSpec(_Tone.neutral, 'Saved'),
  'applied': _PillSpec(_Tone.info, 'Applied'),
  'replied': _PillSpec(_Tone.info, 'Replied'),
  'interview': _PillSpec(_Tone.info, 'Interview'),
  'offer': _PillSpec(_Tone.success, 'Offer'),
  'rejected': _PillSpec(_Tone.critical, 'Rejected'),
};

/// One pill, three semantic contexts — match verdicts, guardrail
/// results, and Kanban pipeline stages. Drive tone with [context] +
/// [value] instead of hand-rolling a colored chip elsewhere.
///
/// ```dart
/// StatusPill(context: PillContext.verdict, value: 'apply')
/// StatusPill(context: PillContext.guardrail, value: 'fail')
/// StatusPill(context: PillContext.stage, value: 'interview', size: PillSize.sm)
/// ```
enum PillSize { sm, md }

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.context,
    required this.value,
    this.size = PillSize.md,
    this.showIcon = true,
  });

  final PillContext context;
  final String value;
  final PillSize size;

  /// Show the leading glyph on verdict/guardrail pills. Stage always
  /// shows a colored dot instead. Default true.
  final bool showIcon;

  _PillSpec _spec() {
    final map = switch (context) {
      PillContext.verdict => _verdictMap,
      PillContext.guardrail => _guardrailMap,
      PillContext.stage => _stageMap,
    };
    return map[value] ?? _PillSpec(_Tone.neutral, value);
  }

  @override
  Widget build(BuildContext ctx) {
    final spec = _spec();
    final t = _toneMap[spec.tone]!;
    final sm = size == PillSize.sm;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: AppRadius.pillRadius,
        border: Border.all(color: t.border),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: sm ? 8 : 10, vertical: sm ? 2 : 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (context == PillContext.stage)
              Container(
                width: sm ? 5 : 6,
                height: sm ? 5 : 6,
                decoration: BoxDecoration(color: t.dot, shape: BoxShape.circle),
              )
            else if (showIcon && spec.icon != null)
              AppIcon(spec.icon!, size: sm ? 12 : 13, color: t.fg),
            if ((context == PillContext.stage) || (showIcon && spec.icon != null))
              SizedBox(width: sm ? 4 : 5),
            Text(
              spec.label,
              style: TextStyle(
                fontFamily: AppTypography.body.fontFamily,
                fontSize: sm ? 11 : 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.06,
                color: t.fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
