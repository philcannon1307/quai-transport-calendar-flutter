import "package:flutter/material.dart";

import "theme/quai_tokens.dart";

export "theme/quai_tokens.dart";

/// App theme: 'official brand palette (light). All values live in theme/quai_tokens.dart.
ThemeData buildTheme() => quaiTheme(Brightness.light);

// --- Legacy aliases (admin / unsubscribe / banner screens, phase 2 will migrate them to context.q) ---
/// Ink (was navy).
const Color kNavy = Color(0xFF222222);

/// Accent ink #8A5A00 for small text002Fborders (name kept for legacy callers).
const Color kPurple = Color(0xFF8A5A00);

/// Legacy card palette. Mapped to the status/service tokens: past = Annulé crimson.
class CardPalette {
  static const Color past = Color(0xFFA3123A);
  static const Color delivInst = Color(0xFF222222);
  static const Color pickups = Color(0xFFFFA500);
  static const Color transfers = Color(0xFF6B5A4D);
}
