import "package:flutter/material.dart";

/// Brand colours from the reference app: navy hsl(222 30% 14%), purple hsl(258 90% 66%).
const Color kNavy = Color(0xFF191D2E);
const Color kPurple = Color(0xFF8A5CF6);

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: kPurple),
    scaffoldBackgroundColor: const Color(0xFFF7F6FB),
    appBarTheme: const AppBarTheme(
      backgroundColor: kNavy,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
  );
}

/// Status colours for calendar cards.
class CardPalette {
  static const Color past = Color(0xFFD64545);
  static const Color delivInst = kPurple;
  static const Color pickups = Color(0xFF0E9F6E);
  static const Color transfers = Color(0xFF2563EB);
}
