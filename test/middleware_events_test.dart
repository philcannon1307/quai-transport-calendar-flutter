import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/calendar_views.dart";
import "package:quai_calendar/logic/middleware_events.dart";

MiddlewareEvent _ev(String title, {String? customer, String? soStatus, String id = "55", String so = "20425"}) =>
    MiddlewareEvent(id: id, title: title, salesOrderId: so, startDate: "2026-11-03", customer: customer, soStatus: soStatus, location: "Ste-Agathe");

void main() {
  group("classification by the LAST title segment (ported from logistique.test.ts)", () {
    test("'Ramassage' / 'Pick-up' titles are pick-ups", () {
      for (final title in <String>[
        "Chibougamau/SO20113/RGL envirotech/Ramassage",
        "Saint-Donat/SO20404/Rudinskas/Ramassage",
        "/SO20237/Ste-Marie/Ramassage",
        "South Frontenac/SO20391/Blair/Pick-up",
      ]) {
        final o = mapMiddlewareEvent(_ev(title))!;
        expect(calendarView(o), CalendarViewKind.pickups, reason: title);
      }
    });

    test("delivery / installation titles are Deliveries & Installations", () {
      for (final title in <String>[
        "SADM - Jayson/SO20425/Showroom  Mirabel/INSTALLATION",
        "SADM - ÉricWentworth Nord/SO20376/Nguyen/Livraison",
        "SO20303/Beaulieu/Val des bois",
      ]) {
        final o = mapMiddlewareEvent(_ev(title))!;
        expect(calendarView(o), CalendarViewKind.delivInst, reason: title);
      }
    });

    test("'cueillette' is a pick-up too", () {
      expect(calendarView(mapMiddlewareEvent(_ev("X/SO1/Y/Cueillette"))!), CalendarViewKind.pickups);
    });
  });

  group("mapping", () {
    test("the SO number is parsed out of the title and upper-cased", () {
      expect(mapMiddlewareEvent(_ev("Mirabel/so20098/Bois/Ramassage"))!.soNum, "SO20098");
    });

    test("a title with no SO is skipped", () {
      expect(mapMiddlewareEvent(_ev("Réunion équipe")), isNull);
    });

    test("customer: the event's own customer wins, else the third segment", () {
      expect(mapMiddlewareEvent(_ev("A/SO1/Third/Livraison", customer: "Acme"))!.customer, "Acme");
      expect(mapMiddlewareEvent(_ev("A/SO1/Third/Livraison"))!.customer, "Third");
    });

    test("'Sales Order :' is stripped from the status", () {
      expect(mapMiddlewareEvent(_ev("A/SO1/B/Livraison", soStatus: "Sales Order : Pending Fulfillment"))!.status, "Pending Fulfillment");
    });

    test("city is the first segment, falling back to the location", () {
      expect(mapMiddlewareEvent(_ev("Chibougamau/SO1/B/Livraison"))!.city, "Chibougamau");
      expect(mapMiddlewareEvent(_ev("/SO1/B/Livraison"))!.city, "Ste-Agathe");
    });

    test("ids and dates carry through", () {
      final o = mapMiddlewareEvent(_ev("A/SO1/B/Livraison", id: "77", so: "9"))!;
      expect(o.serviceEventId, 77);
      expect(o.soId, 9);
      expect(o.date, "2026-11-03");
    });
  });

  group("isSadmEventTitle (kept from the reference)", () {
    test("only SADM truck events qualify", () {
      expect(isSadmEventTitle("SADM - JaysonLa Minerve/SO19976/Laplante/Livraison"), isTrue);
      expect(isSadmEventTitle("SADM - Éric/SO20213/Slimmon/INSTALLATION"), isTrue);
      expect(isSadmEventTitle("Mirabel/SO20098/Bois de Belle Rivière/Ramassage"), isFalse);
      expect(isSadmEventTitle("/SO20082/vallee/INSTALLATION"), isFalse);
    });
  });

  test("MiddlewareEvent.fromJson tolerates missing fields", () {
    final e = MiddlewareEvent.fromJson(<String, dynamic>{"id": 5, "title": "SO1/x/y/z"});
    expect(e.id, "5");
    expect(e.startDate, "");
    expect(e.customer, isNull);
  });
}
