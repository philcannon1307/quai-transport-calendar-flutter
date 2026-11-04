import "dart:convert";
import "package:flutter/material.dart";
import "package:flutter/services.dart" show rootBundle;
import "../l10n/key_map.dart";

/// Bilingual FR/EN dictionary.
///
/// The ARB files under lib/l10n are the source of truth and were generated
/// 1:1 from the reference app's src/lib/i18n.tsx (146 keys per language).
/// Lookup is by the ORIGINAL dotted key so the two dictionaries stay diffable
/// against the React app, and so the three interpolated keys the reference
/// builds at runtime (dow.N, svc.KIND, views.K) keep working.
class Strings {
  Strings(this.locale, this._values);
  final Locale locale;
  final Map<String, String> _values;

  static const List<Locale> supported = <Locale>[Locale("fr"), Locale("en")];

  /// Build a dictionary directly, for widget tests (no asset bundle needed).
  factory Strings.forTests(Map<String, String> arbValues,
          {Locale locale = const Locale("fr")}) =>
      Strings(locale, arbValues);

  static Future<Strings> load(Locale locale) async {
    final code = locale.languageCode == "en" ? "en" : "fr";
    final raw = await rootBundle.loadString("lib/l10n/app_$code.arb");
    final decoded = json.decode(raw) as Map<String, dynamic>;
    final values = <String, String>{};
    decoded.forEach((k, v) {
      if (!k.startsWith("@") && v is String) values[k] = _unescapeIcu(v);
    });
    return Strings(locale, values);
  }

  static String _unescapeIcu(String v) =>
      v.replaceAll("'{'", "{").replaceAll("'}'", "}");

  /// Translate an original dotted key, e.g. t("login.title").
  String t(String dottedKey) {
    final arbKey = kOriginalKeyToArb[dottedKey];
    if (arbKey == null) return dottedKey;
    return _values[arbKey] ?? dottedKey;
  }

  /// Dynamic keys the reference composes at runtime.
  String dow(int index) => t("dow.$index");
  String svc(String kind) => t("svc.$kind");
  String view(String key) => t("views.$key");

  bool get isFrench => locale.languageCode != "en";
}

class StringsScope extends InheritedWidget {
  const StringsScope({super.key, required this.strings, required super.child});
  final Strings strings;
  static Strings of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<StringsScope>();
    assert(s != null, "StringsScope missing");
    return s!.strings;
  }

  @override
  bool updateShouldNotify(StringsScope old) =>
      old.strings.locale != strings.locale;
}
