import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/logic/ticket_cache.dart";
import "package:quai_calendar/logic/ticket_progress.dart";

void main() {
  group("TicketCache (10-minute TTL)", () {
    test("returns the bytes within the TTL", () {
      var now = DateTime(2026, 11, 3, 8);
      final cache = TicketCache(clock: () => now);
      cache.put("SO1", <int>[1, 2, 3]);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(cache.get("SO1"), <int>[1, 2, 3]);
    });

    test("expires at exactly 10 minutes", () {
      var now = DateTime(2026, 11, 3, 8);
      final cache = TicketCache(clock: () => now);
      cache.put("SO1", <int>[1]);
      now = now.add(const Duration(minutes: 10));
      expect(cache.get("SO1"), isNull);
    });

    test("keeps tickets separate and misses unknown ones", () {
      final cache = TicketCache();
      cache.put("SO1", <int>[1]);
      expect(cache.get("SO2"), isNull);
    });
  });

  group("progress easing", () {
    test("starts low and only ever increases while NetSuite builds the PDF", () {
      var p = kStartProgress;
      var last = p;
      for (var ms = 0; ms <= 30000; ms += 200) {
        p = nextServerProgress(p, ms);
        expect(p, greaterThanOrEqualTo(last));
        last = p;
      }
    });

    test("eases toward 70% and never past it", () {
      var p = kStartProgress;
      for (var ms = 0; ms <= 600000; ms += 200) {
        p = nextServerProgress(p, ms);
      }
      expect(p, lessThanOrEqualTo(70.0));
      expect(p, greaterThan(69.0));
    });

    test("is around 44% after 4 seconds", () {
      final p = nextServerProgress(kStartProgress, 4000);
      expect(p, closeTo(44.25, 0.5));
    });

    test("download maps 0..1 onto 70..90", () {
      expect(downloadProgress(40, 0), 70);
      expect(downloadProgress(40, 0.5), 80);
      expect(downloadProgress(40, 1), 90);
    });

    test("unknown length parks at 80", () => expect(downloadProgress(40, null), 80));

    test("never moves backwards", () {
      expect(downloadProgress(85, 0), 85);
      expect(downloadProgress(85, null), 85);
    });
  });
}
