// quai_tokens.dart — Design tokens for Quai Lafantaisie · Calendrier (Flutter) — 'Ember on ink' (Lafantaisie rebrand).
// ONE tokens file: every colour / radius / space / font used by the app comes from here, so official brand
// values can be swapped in a single place. Hex are approximations sampled from the owner's reference image
// until official brand values arrive (charcoal #1A1A1A, light #EDEDED, orange #E8612C).
// Status colours are deliberately NOT the brand orange: Confirmé green, Provisoire mustard + hollow dot, Annulé crimson + strikethrough.
// onPrimary is INK, not white: white on #E8612C is only 3.4:1.
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
    bg: Color(0xFFEDEDED),
    surface: Color(0xFFFFFFFF),
    field: Color(0xFFF3F2F0),
    line: Color(0xFFDDDAD5),
    shadow: Color(0xFFE4E2DE),
    ink: Color(0xFF1A1A1A),
    sub: Color(0xFF5F5C58),
    faint: Color(0xFFA3A09B),
    primary: Color(0xFFE8612C),
    primaryInk: Color(0xFFB8431A),
    primarySoft: Color(0xFFFCE9DF),
    onPrimary: Color(0xFF1A1A1A),
    header: Color(0xFF1A1A1A),
    headerSub: Color(0xFFB5B1AB),
    headerEnd: Color(0xFF2A2A2A),
    install: Color(0xFF1A1A1A),
    delivery: Color(0xFF2F7F93),
    deliveryText: Color(0xFF256A7C),
    pickup: Color(0xFF7A5B3A),
    transfer: Color(0xFF74716E),
    confirmed: Color(0xFF15803D),
    confirmedBg: Color(0xFFDCFCE7),
    tentative: Color(0xFF7A5B00),
    tentativeBg: Color(0xFFF7EBC0),
    cancelled: Color(0xFFA3123A),
    cancelledBg: Color(0xFFFBE3EA),
    memoBg: Color(0xFFFBEBDD),
    memoRail: Color(0xFFE8612C),
  );

  static const dark = QuaiColors(
    bg: Color(0xFF121212),
    surface: Color(0xFF1E1E1E),
    field: Color(0xFF262626),
    line: Color(0xFF333333),
    shadow: Color(0xFF0B0B0B),
    ink: Color(0xFFF2F0EC),
    sub: Color(0xFFA8A49E),
    faint: Color(0xFF77746F),
    primary: Color(0xFFF07A47),
    primaryInk: Color(0xFFF07A47),
    primarySoft: Color(0xFF3A2418),
    onPrimary: Color(0xFF121212),
    header: Color(0xFF0F0F0F),
    headerSub: Color(0xFF96928C),
    headerEnd: Color(0xFF222222),
    install: Color(0xFFE6E2DC),
    delivery: Color(0xFF5FB3C7),
    deliveryText: Color(0xFF5FB3C7),
    pickup: Color(0xFFC9A27A),
    transfer: Color(0xFF9F9C99),
    confirmed: Color(0xFF4ADE80),
    confirmedBg: Color(0xFF12301F),
    tentative: Color(0xFFE9C46A),
    tentativeBg: Color(0xFF33290D),
    cancelled: Color(0xFFF4829E),
    cancelledBg: Color(0xFF3A1520),
    memoBg: Color(0xFF3A2418),
    memoRail: Color(0xFFF07A47),
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
          borderSide: BorderSide(color: c.primary, width: 2)),
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
