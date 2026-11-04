import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/calendar_views.dart";
import "package:quai_calendar/models/order.dart";

Order _order(String serviceType) => Order(
    kind: OrderKind.order,
    soNum: "SO1",
    date: "2026-11-03",
    serviceType: serviceType);

void main() {
  group("SADM - Logistique dispatcher", () {
    final logistique = carrierByDisplayName(kLogistique);

    test("covers all SADM trucks and both Gooseneck trucks", () {
      expect(logistique, isNotNull);
      final trucks = <String>{
        logistique!.truck,
        ...logistique.linkedTrucks.map((t) => t.truck)
      };
      for (final sadm in <String>["62", "43", "45", "54", "63", "44"]) {
        expect(trucks.contains(sadm), isTrue,
            reason: "missing SADM truck $sadm");
      }
      expect(trucks.contains("3"), isTrue);
      expect(trucks.contains("4"), isTrue);
    });

    test("reports go to sadm",
        () => expect(adjustmentInbox(kLogistique), "sadm@groupeql.com"));

    test("does not take over individual trucks", () {
      expect(calendarName("SADM - Éric"), "SADM - Éric");
      expect(calendarName("SADM - Steve"), "SADM - Steve");
    });

    test("only loads the two Gooseneck trucks on sign-in", () {
      final loadable =
          loadableLinkedTrucks(logistique).map((t) => t.displayName).toList();
      expect(loadable, <String>["RIDEAU GOOSENECK", "OPEN GOOSENECK"]);
    });

    test("a normal carrier loads all its linked trucks", () {
      final interql = carrierByDisplayName("InterQL");
      expect(loadableLinkedTrucks(interql).map((t) => t.displayName).toList(),
          <String>["OPEN GOOSENECK"]);
    });

    test("only SADM truck events are kept from the Ste-Agathe source", () {
      expect(isSadmEventTitle("SADM - David / Livraison"), isTrue);
      expect(isSadmEventTitle("  SADM - Steve / Ramassage"), isTrue);
      expect(isSadmEventTitle("Gat - Sam / Livraison"), isFalse);
      expect(isSadmEventTitle("RIDEAU GOOSENECK / TO"), isFalse);
    });
  });

  group("three calendars", () {
    test(
        "delivery -> Deliveries & Installations",
        () => expect(
            calendarView(_order("Livraison")), CalendarViewKind.delivInst));
    test(
        "installation -> Deliveries & Installations",
        () => expect(
            calendarView(_order("Installation")), CalendarViewKind.delivInst));
    test(
        "pick-up -> Pick-ups",
        () =>
            expect(calendarView(_order("Pick-up")), CalendarViewKind.pickups));
    test(
        "cueillette -> Pick-ups",
        () => expect(
            calendarView(_order("Cueillette")), CalendarViewKind.pickups));
    test("transfer -> TOs", () {
      final to = Order(
          kind: OrderKind.transfer,
          soNum: "TO9",
          date: "2026-11-03",
          serviceType: "Transfert / Transfer");
      expect(calendarView(to), CalendarViewKind.transfers);
    });
    test(
        "middleware delivery/installation titles classify as Deliveries & Installations",
        () {
      expect(calendarViewFromTitle("SADM - David / Livraison & Installation"),
          CalendarViewKind.delivInst);
    });
    test("middleware ramassage titles classify as Pick-ups", () {
      expect(calendarViewFromTitle("SADM - Steve / Ramassage"),
          CalendarViewKind.pickups);
      expect(calendarViewFromTitle("SADM - Steve / Pick-up"),
          CalendarViewKind.pickups);
    });
  });
}
