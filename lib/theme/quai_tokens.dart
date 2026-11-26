// quai_tokens.dart — Design tokens for Quai Lafantaisie · Calendrier (Flutter) — official brand palette (Nov 2026).
// Brand: Light Beige #F2F0ED · Beige #DDD9D3 · Light Brown #958272 · Black #222222 · Jaune #FFA500.
// Jaune is a FILL only (text on it is Black #222222, 8.06:1; white on Jaune fails). Accent text/links use primaryInk #8A5A00.
// Light Brown is for icons/borders/disabled, never body text (use sub #6B5A4D). Derived colours are documented in the Designer's brand-palette-remap spec.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Fonts are fetched at runtime by google_fonts (project files are text-only, so the TTFs cannot be bundled).
/// Tests turn this off (test/flutter_test_config.dart) so no HTTP request is attempted.
class QuaiFonts {
  static bool enabled = true;
}

class QuaiColors extends ThemeExtension<QuaiColors> {
  const QuaiColors({
    required this.bg,
    required this.surface,
    required this.field,
    required this.line,
    required this.shadow,
    required this.ink,
    required this.sub,
    required this.faint,
    required this.primary,
    required this.primaryInk,
    required this.primarySoft,
    required this.onPrimary,
    required this.header,
    required this.headerSub,
    required this.headerEnd,
    required this.install,
    required this.delivery,
    required this.deliveryText,
    required this.pickup,
    required this.transfer,
    required this.confirmed,
    required this.confirmedBg,
    required this.tentative,
    required this.tentativeBg,
    required this.cancelled,
    required this.cancelledBg,
    required this.memoBg,
    required this.memoRail,
  });
  final Color bg,
      surface,
      field,
      line,
      shadow,
      ink,
      sub,
      faint,
      primary,
      primaryInk,
      primarySoft,
      onPrimary,
      header,
      headerSub,
      headerEnd,
      install,
      delivery,
      deliveryText,
      pickup,
      transfer,
      confirmed,
      confirmedBg,
      tentative,
      tentativeBg,
      cancelled,
      cancelledBg,
      memoBg,
      memoRail;

  static const light = QuaiColors(
    bg: Color(0xFFF2F0ED),
    surface: Color(0xFFFFFFFF),
    field: Color(0xFFF2F0ED),
    line: Color(0xFFDDD9D3),
    shadow: Color(0xFFDDD9D3),
    ink: Color(0xFF222222),
    sub: Color(0xFF6B5A4D),
    faint: Color(0xFF958272),
    primary: Color(0xFFFFA500),
    primaryInk: Color(0xFF8A5A00),
    primarySoft: Color(0xFFFFF1D6),
    onPrimary: Color(0xFF222222),
    header: Color(0xFF222222),
    headerSub: Color(0xFFB8B2AA),
    headerEnd: Color(0xFF2E2E2E),
    install: Color(0xFF222222),
    delivery: Color(0xFF958272),
    deliveryText: Color(0xFF6B5A4D),
    pickup: Color(0xFFFFA500),
    transfer: Color(0xFF6B5A4D),
    confirmed: Color(0xFF1E6B3A),
    confirmedBg: Color(0xFFDDEFE0),
    tentative: Color(0xFF5F4A36),
    tentativeBg: Color(0xFFEDE6DD),
    cancelled: Color(0xFFA3123A),
    cancelledBg: Color(0xFFFBE3EA),
    memoBg: Color(0xFFFFF1D6),
    memoRail: Color(0xFFFFA500),
  );

  static const dark = QuaiColors(
    bg: Color(0xFF222222),
    surface: Color(0xFF2C2C2C),
    field: Color(0xFF343434),
    line: Color(0xFF444444),
    shadow: Color(0xFF1B1B1B),
    ink: Color(0xFFF2F0ED),
    sub: Color(0xFFB8B2AA),
    faint: Color(0xFF8C857C),
    primary: Color(0xFFFFA500),
    primaryInk: Color(0xFFFFA500),
    primarySoft: Color(0xFF3A2E15),
    onPrimary: Color(0xFF222222),
    header: Color(0xFF1B1B1B),
    headerSub: Color(0xFFB8B2AA),
    headerEnd: Color(0xFF222222),
    install: Color(0xFFF2F0ED),
    delivery: Color(0xFFB3A090),
    deliveryText: Color(0xFFB3A090),
    pickup: Color(0xFFFFA500),
    transfer: Color(0xFFB8B2AA),
    confirmed: Color(0xFF6FD08C),
    confirmedBg: Color(0xFF1F3A29),
    tentative: Color(0xFFD9C7B0),
    tentativeBg: Color(0xFF3A322B),
    cancelled: Color(0xFFF4829E),
    cancelledBg: Color(0xFF3D1D27),
    memoBg: Color(0xFF3A2E15),
    memoRail: Color(0xFFFFA500),
  );

  @override
  QuaiColors copyWith() => this;
  @override
  QuaiColors lerp(ThemeExtension<QuaiColors>? other, double t) =>
      t < .5 ? this : (other as QuaiColors);
}

extension QuaiTheme on BuildContext {
  /// Falls back to the light palette when no Quai theme is installed (bare MaterialApp in tests).
  QuaiColors get q =>
      Theme.of(this).extension<QuaiColors>() ?? QuaiColors.light;
}

class QuaiSpace {
  static const double x1 = 4,
      x2 = 8,
      x3 = 12,
      x4 = 16,
      x5 = 20,
      x6 = 24,
      x8 = 32,
      x12 = 48;
  static const double pagePadPhone = 16,
      pageMaxWidth = 1280,
      tapMin = 44,
      bottomNav = 84;
}

class QuaiRadius {
  static const double xs = 6,
      sm = 10,
      md = 14,
      card = 16,
      lg = 20,
      sheet = 28,
      full = 999;
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(16));
}

class QuaiMotion {
  static const press = Duration(milliseconds: 90),
      hover = Duration(milliseconds: 120),
      segment = Duration(milliseconds: 220),
      sheet = Duration(milliseconds: 280),
      fade = Duration(milliseconds: 180);
  static const Curve out = Curves.easeOutCubic,
      sheetCurve = Curves.easeOutQuint;
}

class QuaiBreakpoints {
  static const double phone = 700, wide = 1100;
}

List<BoxShadow> quaiShadow(QuaiColors c, {int level = 1}) => switch (level) {
      0 => const [],
      1 => [
          BoxShadow(color: c.shadow, offset: const Offset(0, 2), blurRadius: 6)
        ],
      _ => [
          BoxShadow(color: c.shadow, offset: const Offset(0, 8), blurRadius: 24)
        ],
    };

TextStyle _font(String family, double size, double height, FontWeight w,
    Color color, double ls) {
  if (!QuaiFonts.enabled) {
    return TextStyle(
        fontFamily: family,
        fontSize: size,
        height: height / size,
        fontWeight: w,
        color: color,
        letterSpacing: ls);
  }
  switch (family) {
    case 'Newsreader':
      return GoogleFonts.newsreader(
          fontSize: size,
          height: height / size,
          fontWeight: w,
          color: color,
          letterSpacing: ls);
    case 'JetBrains Mono':
      return GoogleFonts.jetBrainsMono(
          fontSize: size,
          height: height / size,
          fontWeight: w,
          color: color,
          letterSpacing: ls);
    default:
      return GoogleFonts.interTight(
          fontSize: size,
          height: height / size,
          fontWeight: w,
          color: color,
          letterSpacing: ls);
  }
}

/// UI font (Inter Tight).
TextStyle quaiSans(Color c,
        {double size = 14,
        double? height,
        FontWeight weight = FontWeight.w500,
        double ls = 0}) =>
    _font('Inter Tight', size, height ?? size * 1.4, weight, c, ls);

TextTheme quaiTextTheme(Color ink) {
  final base = QuaiFonts.enabled
      ? GoogleFonts.interTightTextTheme()
      : Typography.material2021().black;
  TextStyle s(double size, double h, FontWeight w, {double ls = 0}) =>
      _font('Inter Tight', size, h, w, ink, ls);
  return base.copyWith(
    displaySmall: s(28, 34, FontWeight.w700), // Connexion
    titleLarge: s(20, 26, FontWeight.w700), // date range, section titles
    titleMedium: s(15, 20, FontWeight.w700), // card title (client)
    bodyLarge: s(16, 22, FontWeight.w500),
    bodyMedium: s(14, 20, FontWeight.w500),
    bodySmall: s(12, 16, FontWeight.w500), // captions
    labelLarge: s(14, 20, FontWeight.w700),
    labelSmall:
        s(10, 12, FontWeight.w700, ls: .8), // CAPS labels (KPI, day names)
  );
}

/// Accent serif for editorial moments only (sign-in tagline, empty states): never for data.
TextStyle quaiSerif(Color c, {double size = 16}) =>
    _font('Newsreader', size, size * 1.3, FontWeight.w400, c, 0);

/// SO# and other identifiers.
TextStyle quaiMono(Color c, {double size = 12}) =>
    _font('JetBrains Mono', size, 16, FontWeight.w700, c, 0);

ThemeData quaiTheme(Brightness b) {
  final c = b == Brightness.light ? QuaiColors.light : QuaiColors.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: c.bg,
    extensions: [c],
    colorScheme: ColorScheme.fromSeed(seedColor: c.primary, brightness: b)
        .copyWith(
            primary: c.primary,
            onPrimary: c.onPrimary,
            surface: c.surface,
            onSurface: c.ink,
            outline: c.line,
            error: c.cancelled),
    textTheme: quaiTextTheme(c.ink),
    dividerColor: c.line,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.line)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
              color: b == Brightness.light ? c.ink : c.primary, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            backgroundColor: c.primary,
            foregroundColor: c.onPrimary,
            minimumSize: const Size.fromHeight(56),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            textStyle:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
    appBarTheme: AppBarTheme(
        backgroundColor: c.header,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false),
  );
}
