import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/logic/order_windows.dart";
import "package:quai_calendar/models/order.dart";

void main() {
  group("2 AM past-card rule", () {
    test("yesterday is past once it is 02:00 today", () {
      final now = DateTime(2026, 11, 3, 2, 0);
      expect(OrderWindows.isPast(DateTime(2026, 11, 2), now), isTrue);
    });
    test("today is not past at 02:00", () {
      final now = DateTime(2026, 11, 3, 2, 0);
      expect(OrderWindows.isPast(DateTime(2026, 11, 3), now), isFalse);
    });
    test("yesterday is still current at 01:59", () {
      final now = DateTime(2026, 11, 3, 1, 59);
      expect(OrderWindows.isPast(DateTime(2026, 11, 2, 12), now), isFalse);
    });
  });

  group("upcoming window", () {
    final now = DateTime(2026, 11, 3, 9);
    test(
        "today counts as upcoming",
        () => expect(
            OrderWindows.isUpcomingWithin(DateTime(2026, 11, 3), now, 1),
            isTrue));
    test(
        "six days ahead is inside one week",
        () => expect(
            OrderWindows.isUpcomingWithin(DateTime(2026, 11, 9), now, 1),
            isTrue));
    test(
        "eight days ahead is outside one week",
        () => expect(
            OrderWindows.isUpcomingWithin(DateTime(2026, 11, 11), now, 1),
            isFalse));
    test(
        "eight days ahead is inside two weeks",
        () => expect(
            OrderWindows.isUpcomingWithin(DateTime(2026, 11, 11), now, 2),
            isTrue));
    test(
        "yesterday is not upcoming",
        () => expect(
            OrderWindows.isUpcomingWithin(DateTime(2026, 11, 2), now, 2),
            isFalse));
  });

  group("calendar spans", () {
    test("7 and 14 day spans", () {
      expect(OrderWindows.days(DateTime(2026, 11, 3), 7).length, 7);
      expect(OrderWindows.days(DateTime(2026, 11, 3), 14).length, 14);
    });
  });

  group("transfer numbers", () {
    test("TO numbers detected", () {
      expect(isTransferNum("TO12345"), isTrue);
      expect(isTransferNum(" to999 "), isTrue);
      expect(isTransferNum("SO12345"), isFalse);
      expect(isTransferNum(null), isFalse);
    });
  });

  group("transfer mapping", () {
    test("maps from/to locations and strips the status prefix", () {
      final o = Order.fromTransfer(<String, dynamic>{
        "toNum": "TO555",
        "toId": 9,
        "fromLocationName": "Ste-Agathe",
        "toLocationName": "Lindsay",
        "status": "Transfer Order : Pending Receipt",
        "date": "2026-11-05",
        "eventStartDate": "2026-11-05",
      });
      expect(o.kind, OrderKind.transfer);
      expect(o.soNum, "TO555");
      expect(o.customer, "Ste-Agathe → Lindsay");
      expect(o.status, "Pending Receipt");
      expect(o.serviceType, "Transfert / Transfer");
    });
    test("shell rows are identified", () {
      expect(Order.isShell(<String, dynamic>{"isShell": true}), isTrue);
      expect(Order.isShell(<String, dynamic>{"isShell": false}), isFalse);
    });
  });

  group("2 AM rollover boundary (regression)", () {
    test("at 01:59 the business day is still yesterday", () {
      expect(OrderWindows.businessDate(DateTime(2026, 11, 3, 1, 59)),
          DateTime(2026, 11, 2));
    });
    test("at 02:00 the business day becomes today", () {
      expect(OrderWindows.businessDate(DateTime(2026, 11, 3, 2, 0)),
          DateTime(2026, 11, 3));
    });
    test("a job dated today is never past, whatever the hour", () {
      for (final h in <int>[0, 1, 2, 9, 23]) {
        final now = DateTime(2026, 11, 3, h);
        expect(OrderWindows.isPast(DateTime(2026, 11, 3), now), isFalse,
            reason: "hour=" + h.toString());
      }
    });
    test("yesterday flips to past exactly at 02:00", () {
      expect(
          OrderWindows.isPast(
              DateTime(2026, 11, 2), DateTime(2026, 11, 3, 1, 59)),
          isFalse);
      expect(
          OrderWindows.isPast(
              DateTime(2026, 11, 2), DateTime(2026, 11, 3, 2, 0)),
          isTrue);
    });
    test("time of day on the order does not change its day classification", () {
      final now = DateTime(2026, 11, 3, 9);
      expect(OrderWindows.isPast(DateTime(2026, 11, 3, 23, 59), now), isFalse);
      expect(OrderWindows.isPast(DateTime(2026, 11, 2, 23, 59), now), isTrue);
    });
    test("before rollover, yesterday still counts as upcoming", () {
      expect(
          OrderWindows.isUpcomingWithin(
              DateTime(2026, 11, 2), DateTime(2026, 11, 3, 1, 0), 1),
          isTrue);
    });
  });
}
