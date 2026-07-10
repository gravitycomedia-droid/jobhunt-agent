import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// Token/tag input for target roles, skills, locations (Brick 9
/// onboarding's Target Roles step). Type and press Enter or comma to
/// add a chip; tap ✕ or press Backspace on an empty draft to remove
/// the last one. Controlled via [value] + [onChange].
///
/// ```dart
/// ChipInput(
///   label: 'Target roles',
///   value: _roles,
///   onChange: (next) => setState(() => _roles = next),
/// )
/// ```
class ChipInput extends StatefulWidget {
  const ChipInput({
    super.key,
    this.label,
    required this.value,
    required this.onChange,
    this.placeholder = 'Add and press Enter',
    this.hint,
    this.max,
  });

  final String? label;
  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final String placeholder;
  final String? hint;

  /// Optional max number of chips.
  final int? max;

  @override
  State<ChipInput> createState() => _ChipInputState();
}

class _ChipInputState extends State<ChipInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _focused = _focusNode.hasFocus);
      if (!_focused) _commit(_controller.text);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final t = raw.trim().replaceAll(RegExp(r',$'), '').trim();
    if (t.isEmpty) return;
    if (widget.value.contains(t)) {
      _controller.clear();
      return;
    }
    if (widget.max != null && widget.value.length >= widget.max!) return;
    widget.onChange([...widget.value, t]);
    _controller.clear();
  }

  void _removeAt(int i) {
    final next = [...widget.value]..removeAt(i);
    widget.onChange(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.comma) {
      _commit(_controller.text);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace && _controller.text.isEmpty && widget.value.isNotEmpty) {
      _removeAt(widget.value.length - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(widget.label!, style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
          ),
        GestureDetector(
          onTap: () => _focusNode.requestFocus(),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.smRadius,
              border: Border.all(color: _focused ? AppColors.brand500 : AppColors.borderStrong, width: 1.5),
              boxShadow: _focused ? AppElevation.focusShadow : null,
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < widget.value.length; i++) _Chip(label: widget.value[i], onRemove: () => _removeAt(i)),
                SizedBox(
                  width: 100,
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      decoration: InputDecoration(
                        hintText: widget.value.isEmpty ? widget.placeholder : '',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 3),
                      ),
                      style: AppTypography.body,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(widget.hint!, style: AppTypography.caption),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.brandSoft,
        border: Border.all(color: AppColors.brandSoftBorder),
        borderRadius: AppRadius.pillRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 6, top: 3, bottom: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brand700)),
            const SizedBox(width: 5),
            InkWell(
              onTap: onRemove,
              child: const AppIcon(AppIconName.x, size: 13, color: AppColors.brand600),
            ),
          ],
        ),
      ),
    );
  }
}
