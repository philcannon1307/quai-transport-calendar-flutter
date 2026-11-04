import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/concurrency_limiter.dart";
import "package:quai_calendar/api/contact_service.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/logic/contact_parser.dart";

const List<String> _ticket = <String>[
  "Picking Ticket",
  "SO20113",
  "Client:",
  "Jean Tremblay",
  "123 rue Principale",
  "Saint-Donat QC J0T 2C0",
  "Phone: 819-555-0142",
  "Ship Via: Truck",
];

void main() {
  group("parseContact (template 146)", () {
    test("reads phone and the street/city block after the customer name", () {
      final c = parseContact(_ticket, "SO20113");
      expect(c.phone, "819-555-0142");
      expect(c.address, "123 rue Principale, Saint-Donat QC J0T 2C0");
    });

    test("the customer name (first line) is never part of the address", () {
      expect(parseContact(_ticket, "SO20113").address,
          isNot(contains("Tremblay")));
    });

    test("the SO number echoed inside the block is dropped", () {
      final lines = <String>[
        "Client:",
        "SO20113",
        "Jean Tremblay",
        "9 chemin du Lac",
        "Mirabel QC",
        "Phone: 450-555-0000"
      ];
      expect(parseContact(lines, "so20113").address,
          "9 chemin du Lac, Mirabel QC");
    });

    test("French 'Téléphone :' is recognised", () {
      final lines = <String>[
        "Client",
        "Marie Roy",
        "5 rue X",
        "Phone: 1",
        "Téléphone : 514 555 1212"
      ];
      expect(
          parseContact(<String>[
            "Client",
            "Marie Roy",
            "5 rue X",
            "Téléphone : 514 555 1212"
          ], "SO1")
              .phone,
          "514 555 1212");
      expect(parseContact(lines, "SO1").phone, "1");
    });

    test(
        "a phone number containing a colon-free value keeps everything after the first colon",
        () {
      expect(parseContact(<String>["Phone: ext: 22 819-555-1111"], "SO1").phone,
          "ext: 22 819-555-1111");
    });

    test("an empty phone value is null, not an empty string", () {
      expect(parseContact(<String>["Phone:"], "SO1").phone, isNull);
    });

    test("no Client heading means no address", () {
      final c = parseContact(
          <String>["Jean", "1 rue A", "Phone: 819-555-0142"], "SO1");
      expect(c.phone, "819-555-0142");
      expect(c.address, isNull);
    });

    test("a phone line BEFORE the Client heading yields no address", () {
      final c = parseContact(
          <String>["Phone: 819-555-0142", "Client:", "Jean", "1 rue A"], "SO1");
      expect(c.address, isNull);
    });

    test("a customer with no street line yields no address", () {
      expect(
          parseContact(
                  <String>["Client:", "Jean", "Phone: 819-555-0142"], "SO1")
              .address,
          isNull);
    });

    test("blank lines and padding are ignored", () {
      final c = parseContact(<String>[
        "  ",
        "Client:  ",
        " Jean ",
        "  1 rue A ",
        "",
        "Phone:  819-555-0142  "
      ], "SO1");
      expect(c.address, "1 rue A");
      expect(c.phone, "819-555-0142");
    });

    test("nothing recognisable gives an empty contact", () {
      expect(parseContact(<String>["hello", "world"], "SO1").isEmpty, isTrue);
    });
  });

  group("links", () {
    test("tel: keeps digits and a leading plus only", () {
      expect(telHref("(819) 555-0142"), "tel:8195550142");
      expect(telHref("+1 819 555 0142"), "tel:+18195550142");
    });

    test("Maps directions link encodes the address", () {
      expect(
        mapsHref("123 rue Principale, Saint-Donat"),
        "https://www.google.com/maps/dir/?api=1&destination=123%20rue%20Principale%2C%20Saint-Donat",
      );
    });

    test("PDF text is split on both newline styles", () {
      expect(linesFromPdfText("a\r\nb\nc"), <String>["a", "b", "c"]);
    });
  });

  group("ConcurrencyLimiter", () {
    test("never runs more than 2 at once and finishes all", () async {
      final limiter = ConcurrencyLimiter(2);
      var running = 0;
      var peak = 0;
      final results = await Future.wait<int>(List<Future<int>>.generate(7, (i) {
        return limiter.run<int>(() async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
          return i;
        });
      }));
      expect(peak, 2);
      expect(results, <int>[0, 1, 2, 3, 4, 5, 6]);
    });

    test("a failing task does not block the queue", () async {
      final limiter = ConcurrencyLimiter(1);
      final bad = limiter.run<int>(() async => throw StateError("boom"));
      final good = limiter.run<int>(() async => 5);
      await expectLater(bad, throwsStateError);
      expect(await good, 5);
    });
  });

  group("ContactService", () {
    ContactService make({
      required PdfTextExtractor extractor,
      Future<List<int>> Function(String)? fetch,
      MemorySessionStore? store,
    }) {
      return ContactService(
        fetchTicket: fetch ?? (so) async => <int>[1],
        extractor: extractor,
        store: store ?? MemorySessionStore(),
      );
    }

    test("extracts once, caches it, and serves the second call from cache",
        () async {
      final ex = _CountingExtractor(_ticket);
      final svc = make(extractor: ex);
      final a = await svc.contactFor("SO20113");
      final b = await svc.contactFor("SO20113");
      expect(a?.phone, "819-555-0142");
      expect(b?.address, "123 rue Principale, Saint-Donat QC J0T 2C0");
      expect(ex.calls, 1);
    });

    test("concurrent requests for the same order share one extraction",
        () async {
      final ex =
          _CountingExtractor(_ticket, delay: const Duration(milliseconds: 10));
      final svc = make(extractor: ex);
      final r = await Future.wait<OrderContact?>(<Future<OrderContact?>>[
        svc.contactFor("SO1"),
        svc.contactFor("SO1"),
        svc.contactFor("SO1")
      ]);
      expect(ex.calls, 1);
      expect(r.every((c) => c?.phone == "819-555-0142"), isTrue);
    });

    test(
        "an unreadable PDF gives null and is NOT cached, so the next try re-extracts",
        () async {
      final ex = _CountingExtractor(null);
      final svc = make(extractor: ex);
      expect(await svc.contactFor("SO1"), isNull);
      expect(await svc.contactFor("SO1"), isNull);
      expect(ex.calls, 2);
    });

    test("a ticket with neither phone nor address is not cached", () async {
      final ex = _CountingExtractor(<String>["nothing useful"]);
      final svc = make(extractor: ex);
      await svc.contactFor("SO1");
      await svc.contactFor("SO1");
      expect(ex.calls, 2);
    });

    test("a failed ticket download yields null instead of an error", () async {
      final svc = make(
          extractor: _CountingExtractor(_ticket),
          fetch: (so) async => throw StateError("404"));
      expect(await svc.contactFor("SO1"), isNull);
    });

    test("never processes more than 2 PDFs at once across different orders",
        () async {
      final ex =
          _CountingExtractor(_ticket, delay: const Duration(milliseconds: 8));
      final svc = make(extractor: ex);
      await Future.wait<OrderContact?>(List<Future<OrderContact?>>.generate(
          6, (i) => svc.contactFor("SO$i")));
      expect(ex.peak, 2);
    });

    test("a corrupt cache entry is ignored and re-extracted", () async {
      final store = MemorySessionStore()
        ..write("quai:contact:v1:SO1", "{not json");
      final svc = make(extractor: _CountingExtractor(_ticket), store: store);
      expect((await svc.contactFor("SO1"))?.phone, "819-555-0142");
    });
  });
}

class _CountingExtractor implements PdfTextExtractor {
  _CountingExtractor(this.lines, {this.delay = Duration.zero});
  final List<String>? lines;
  final Duration delay;
  int calls = 0;
  int running = 0;
  int peak = 0;

  @override
  Future<List<String>?> firstPageLines(List<int> pdfBytes) async {
    calls++;
    running++;
    if (running > peak) peak = running;
    await Future<void>.delayed(delay);
    running--;
    return lines;
  }
}
