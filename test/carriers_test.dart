import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/data/carriers.dart";

void main() {
  group("retired Gatineau Solution Lac accounts", () {
    test("excludes the owner and both driver accounts from the active roster",
        () {
      expect(
          kCarriers
              .where((c) => RegExp("solution lac", caseSensitive: false)
                  .hasMatch(c.displayName))
              .toList(),
          isEmpty);
      expect(
          kCarriers
              .where((c) => c.group == "Gatineau")
              .map((c) => c.displayName)
              .toList(),
          <String>["Gat - Sam"]);
    });

    for (final name in <String>[
      "Gat - Solution Lac",
      "Gat - Solution Lac #1",
      "Gat - Solution Lac #2"
    ]) {
      test("clears an existing session for $name and saved linked credentials",
          () {
        final store = MemorySessionStore();
        final session = Session(store);
        store.write(kNameKey, name);
        store.write(kTokenKey, "test-token");
        store.write(kLinkedCredsKey, "test-credentials");
        store.write(kLinkedKey, "[]");
        expect(session.token(), isNull);
        expect(store.read(kNameKey), isNull);
        expect(store.read(kLinkedCredsKey), isNull);
        expect(store.read(kLinkedKey), isNull);
      });
    }

    test("keeps Gat - Sam signed in", () {
      final store = MemorySessionStore();
      final session = Session(store);
      store.write(kNameKey, "Gat - Sam");
      store.write(kTokenKey, "test-token");
      expect(session.token(), "test-token");
    });
  });
}
