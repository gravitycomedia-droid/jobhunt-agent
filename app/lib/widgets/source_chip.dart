import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Phase 3 — the brand-monogram source tile (FLUTTER_GUIDE §6).
///
/// A small rounded square carrying a job board's brand colour + monogram.
/// `jobs.source` has **no CHECK constraint** server-side, so any string can
/// arrive; the plan requires 11 known sources plus a neutral fallback that
/// renders the first letter on a themed tile and **never crashes** on an
/// unmapped value. Lookup is case-insensitive.
///
/// Swap the monogram for a real logo asset later — this is the placeholder tile.
class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.source, this.size = 18});

  final String source;
  final double size;

  /// 11 known sources → (brand colour, monogram). Keys are lower-case; brand
  /// colours are intrinsic brand identities, not theme tokens.
  static const Map<String, (Color, String)> _brand = {
    'linkedin': (Color(0xFF0A66C2), 'in'),
    'indeed': (Color(0xFF2557A7), 'Id'),
    'naukri': (Color(0xFF4A76BC), 'N'),
    'internshala': (Color(0xFF0087C5), 'i'),
    'unstop': (Color(0xFF5B3DF6), 'U'),
    'adzuna': (Color(0xFF00B0B9), 'A'),
    'jsearch': (Color(0xFF6B58E6), 'JS'),
    'greenhouse': (Color(0xFF24A47C), 'G'),
    'lever': (Color(0xFF5423E7), 'L'),
    'google_form': (Color(0xFF4285F4), 'G'),
    'manual': (Color(0xFF5B5B66), 'M'),
  };

  @override
  Widget build(BuildContext context) {
    final key = source.trim().toLowerCase();
    final known = _brand[key];

    if (known != null) {
      final (col, mono) = known;
      return _tile(bg: col, fg: Colors.white, label: mono, border: null);
    }

    // Neutral fallback — first letter on a themed tile. Guaranteed non-empty
    // label even for an empty/whitespace source string.
    final c = context.c;
    final letter = key.isEmpty ? '?' : key.characters.first.toUpperCase();
    return _tile(bg: c.surface2, fg: c.inkSoft, label: letter, border: c.border);
  }

  Widget _tile({required Color bg, required Color fg, required String label, Color? border}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          // Two-letter monograms (e.g. "in", "JS") need a smaller glyph to fit.
          fontSize: size * (label.length > 1 ? 0.38 : 0.5),
          height: 1,
        ),
      ),
    );
  }
}
