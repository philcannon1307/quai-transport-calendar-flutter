import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/data/carriers.dart";

void main() {
  group("InterQL", () {
    test("provides one login covering trucks 3 and 4", () {
      final interql = carrierByDisplayName("InterQL");
      expect(interql, isNotNull);
      expect(interql!.truck, "3");
      expect(interql.backendUsername, "RIDEAU GOOSENECK");
      expect(interql.linkedTrucks.map((t) => t.truck).toList(), <String>["4"]);
      expect(interql.linkedTrucks.map((t) => t.displayName).toList(), <String>["OPEN GOOSENECK"]);
    });

    test("both Gooseneck accounts resolve to the InterQL calendar name", () {
      expect(calendarName("RIDEAU GOOSENECK"), "InterQL");
      expect(calendarName("OPEN GOOSENECK"), "InterQL");
    });

    test("admin aggregation includes both trucks without an InterQL login", () {
      final accounts = carrierAccounts(kCarriers);
      final trucks = accounts.map((a) => a.truck).toSet();
      expect(trucks.contains("3"), isTrue);
      expect(trucks.contains("4"), isTrue);
    });

    test("one backend account per username, no duplicates", () {
      final accounts = carrierAccounts(kCarriers);
      final usernames = accounts.map((a) => a.username).toList();
      expect(usernames.length, usernames.toSet().length);
    });
  });
}
