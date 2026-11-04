import "dart:io";
import "package:flutter_test/flutter_test.dart";

/// Guards against shipping an untranslated key to a driver.
///
/// A preview once rendered the literal text "login.code" as a field label
/// because the key was invented rather than taken from the dictionary. This
/// test scans every .t("…") call in lib/ and fails if the key is not defined.
void main() {
  test("every translated key used in lib/ exists in the dictionary", () {
    final keyMap = File("lib/l10n/key_map.dart").readAsStringSync();
    final available = RegExp('"([^"]+)":\\s*"[^"]+",')
        .allMatches(keyMap)
        .map((m) => m.group(1)!)
        .toSet();
    expect(available.length, greaterThan(100),
        reason: "dictionary failed to parse");

    final used = <String, List<String>>{};
    for (final entity in Directory("lib").listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith(".dart")) continue;
      final src = entity.readAsStringSync();
      for (final m in RegExp(r'\.t\(\s*"([^"]+)"').allMatches(src)) {
        used.putIfAbsent(m.group(1)!, () => <String>[]).add(entity.path);
      }
    }
    expect(used, isNotEmpty,
        reason: "no translated keys found — scanner broken");

    final missing = used.keys.where((k) => !available.contains(k)).toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: "keys not in the dictionary: " +
          missing.map((k) => k + " (" + used[k]!.join(", ") + ")").join("; "),
    );
  });

  test("dynamic key families resolve for every value the UI can produce", () {
    final keyMap = File("lib/l10n/key_map.dart").readAsStringSync();
    final available = RegExp('"([^"]+)":\\s*"[^"]+",')
        .allMatches(keyMap)
        .map((m) => m.group(1)!)
        .toSet();
    for (final k in <String>[
      "views.delivInst",
      "views.pickups",
      "views.transfers"
    ]) {
      expect(available.contains(k), isTrue, reason: k);
    }
    for (var i = 0; i < 7; i++) {
      expect(available.contains("dow.$i"), isTrue, reason: "dow.$i");
    }
  });
}
