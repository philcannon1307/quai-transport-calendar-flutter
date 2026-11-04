import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/api_client.dart";

void main() {
  group("cache-busting URLs", () {
    const base = ApiClient.kJobServiceBaseUrl;

    test("adds ?_= when the path has no query", () {
      expect(
        ApiClient.cacheBustedUrl(
            base, "/api/ship-calendar/orders", 1730000000000),
        "$base/api/ship-calendar/orders?_=1730000000000",
      );
    });

    test("adds &_= when the path already has a query", () {
      expect(
        ApiClient.cacheBustedUrl(
            base, "/api/netsuite/events?location=Ste-Agathe", 42),
        "$base/api/netsuite/events?location=Ste-Agathe&_=42",
      );
    });

    test("the separator is never swallowed into the parameter name", () {
      final url = ApiClient.cacheBustedUrl(base, "/x", 7);
      expect(url.endsWith("?_=7"), isTrue, reason: url);
      expect(url.contains("_=7"), isTrue);
    });

    test("every read is uniquely busted", () {
      final a = ApiClient.cacheBustedUrl(base, "/x", 1);
      final b = ApiClient.cacheBustedUrl(base, "/x", 2);
      expect(a == b, isFalse);
    });
  });
}
