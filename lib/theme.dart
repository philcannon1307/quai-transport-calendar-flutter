import "package:flutter/material.dart";

import "theme/quai_tokens.dart";

export "theme/quai_tokens.dart";

/// App theme: 'Ember on ink' (light). All values live in theme/quai_tokens.dart.
ThemeData buildTheme() => quaiTheme(Brightness.light);

// --- Legacy aliases (admin / unsubscribe / banner screens, phase 2 will migrate them to context.q) ---
/// Ink (was navy).
const Color kNavy = Color(0xFF1A1A1A);
/// Brand orange for small text/borders (primary-ink; was purple).
const Color kPurple = Color(0xFFB8431A);

/// Legacy card palette. Mapped to the status/service tokens: past = Annulé crimson.
class CardPalette {
  static const Color past = Color(0xFFA3123A);
  static const Color delivInst = Color(0xFF1A1A1A);
  static const Color pickups = Color(0xFF7A5B3A);
  static const Color transfers = Color(0xFF74716E);
}
