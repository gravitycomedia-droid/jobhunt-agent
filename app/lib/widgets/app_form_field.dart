import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';

/// Labeled text input with hint + error states — the base text-entry
/// surface for Profile Review, and later Settings / Sign In (Brick 9).
///
/// ```dart
/// AppFormField(
///   label: 'Full name',
///   controller: _nameController,
///   required: true,
///   error: _nameError,
/// )
/// ```
class AppFormField extends StatelessWidget {
  const AppFormField({
    super.key,
    this.label,
    this.controller,
    this.onChanged,
    this.placeholder,
    this.hint,
    this.error,
    this.required = false,
    this.disabled = false,
    this.multiline = false,
    this.rows = 3,
    this.keyboardType,
    this.obscureText = false,
  });

  final String? label;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final String? placeholder;

  /// Helper text below the field.
  final String? hint;

  /// Error message (overrides [hint], turns the field critical).
  final String? error;

  /// Marks required — adds a red asterisk next to the label.
  final bool required;
  final bool disabled;

  /// Render a multi-line text area instead of a single-line input.
  final bool multiline;

  /// Text-area line count when [multiline] is true. Default 3.
  final int rows;

  final TextInputType? keyboardType;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null;
    final borderColor = hasError ? context.c.critical : context.c.border;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: RichText(
              text: TextSpan(
                text: label,
                style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
                children: required
                    ? [TextSpan(text: ' *', style: TextStyle(color: context.c.critical))]
                    : null,
              ),
            ),
          ),
        TextField(
          controller: controller,
          onChanged: onChanged,
          enabled: !disabled,
          maxLines: multiline ? rows : 1,
          keyboardType: keyboardType ?? (multiline ? TextInputType.multiline : TextInputType.text),
          obscureText: obscureText,
          style: AppTypography.body,
          decoration: InputDecoration(
            hintText: placeholder,
            filled: true,
            fillColor: disabled ? context.c.surface2 : context.c.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: OutlineInputBorder(borderRadius: AppRadius.smRadius, borderSide: BorderSide(color: borderColor, width: 1.5)),
            enabledBorder: OutlineInputBorder(borderRadius: AppRadius.smRadius, borderSide: BorderSide(color: borderColor, width: 1.5)),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadius.smRadius,
              borderSide: BorderSide(color: hasError ? context.c.critical : context.c.accent, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(borderRadius: AppRadius.smRadius, borderSide: BorderSide(color: context.c.critical, width: 1.5)),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(error!, style: AppTypography.caption.copyWith(color: context.c.critical, fontWeight: FontWeight.w500)),
          )
        else if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(hint!, style: AppTypography.caption),
          ),
      ],
    );
  }
}
