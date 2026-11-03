import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/ticket_cache.dart";
import "package:quai_calendar/logic/ticket_progress.dart";

class _Tokens implements TicketTokens {
  _Tokens({this.primary = "own", this.name = "Gat - Sam", this.toTokens = const <String, String>{}, this.sadm = const <String>[]});
  final String? primary;
  final String? name;
  final Map<String, String> toTokens;
  final List<String> sadm;
  @override
  String? primaryToken() => primary;
  @override
  String? transferToken(String toNum) => toTokens[toNum.toUpperCase()];
  @override
  String? carrierName() => name;
  @override
  List<String> sadmTruckTokens() => sadm;
}

/// Records every request and answers from a per-call script.
class _Net {
  _Net(this.answer);
  final TicketHttpResult Function(String? token, String num, int callIndex) answer;
  final List<String?> tokensSeen = <String?>[];
  final List<String> numsSeen = <String>[];

  Future<TicketHttpResult> call(String? token, String ticketNum, {void Function(double? fraction)? onDownload}) async {
    final i = tokensSeen.length;
    tokensSeen.add(token);
    numsSeen.add(ticketNum);
    return answer(token, ticketNum, i);
  }
}

TicketHttpResult _pdf([List<int> bytes = const <int>[37, 80, 68, 70]]) => TicketHttpResult(200, bytes);
const TicketHttpResult _notFound = TicketHttpResult(404);

TicketService _service(_Net net, _Tokens tokens, {TicketCache? cache}) =>
    TicketService(fetch: net.call, tokens: tokens, cache: cache, retryDelay: Duration.zero);

void main() {
  group("owning-truck token", () {
    test("a sales order uses the session token", () async {
      final net = _Net((t, n, i) => _pdf());
      await _service(net, _Tokens(primary: "own")).getTicket("SO20113");
      expect(net.tokensSeen, <String?>["own"]);
    });

    test("a transfer uses the token of the Gooseneck truck that OWNS it, not the session's", () async {
      final net = _Net((t, n, i) => _pdf());
      final tokens = _Tokens(primary: "rideau-3", toTokens: <String, String>{"TO555": "open-4"});
      await _service(net, tokens).getTicket("TO555");
      expect(net.tokensSeen, <String?>["open-4"]);
    });

    test("a transfer with no recorded owner falls back to the session token", () async {
      final net = _Net((t, n, i) => _pdf());
      await _service(net, _Tokens(primary: "rideau-3")).getTicket("TO999");
      expect(net.tokensSeen, <String?>["rideau-3"]);
    });
  });

  group("404 handling", () {
    test("a 404 is retried ONCE and the second answer is used", () async {
      final net = _Net((t, n, i) => i == 0 ? _notFound : _pdf(<int>[9, 9]));
      final bytes = await _service(net, _Tokens()).getTicket("SO1");
      expect(net.tokensSeen.length, 2);
      expect(bytes, <int>[9, 9]);
    });

    test("two 404s in a row fail with the friendly message after exactly 2 requests", () async {
      final net = _Net((t, n, i) => _notFound);
      await expectLater(
        _service(net, _Tokens()).getTicket("SO1"),
        throwsA(isA<TicketException>().having((e) => e.status, "status", 404).having((e) => e.message, "message", contains("temporairement indisponible"))),
      );
      expect(net.tokensSeen.length, 2);
    });
  });

  group("stale session", () {
    for (final status in <int>[401, 403]) {
      test("$status is reported as unauthorized and never retried", () async {
        final net = _Net((t, n, i) => TicketHttpResult(status));
        await expectLater(
          _service(net, _Tokens()).getTicket("SO1"),
          throwsA(isA<TicketException>().having((e) => e.unauthorized, "unauthorized", isTrue)),
        );
        expect(net.tokensSeen.length, 1);
      });
    }

    test("a network failure (status 0) is a clear error, not a crash", () async {
      final net = _Net((t, n, i) => const TicketHttpResult(0));
      await expectLater(_service(net, _Tokens()).getTicket("SO1"), throwsA(isA<TicketException>().having((e) => e.status, "status", 0)));
    });
  });

  group("10-minute cache", () {
    test("a second open within 10 minutes makes no request", () async {
      var now = DateTime(2026, 11, 3, 8);
      final net = _Net((t, n, i) => _pdf());
      final svc = _service(net, _Tokens(), cache: TicketCache(clock: () => now));
      await svc.getTicket("SO1");
      now = now.add(const Duration(minutes: 9));
      await svc.getTicket("SO1");
      expect(net.tokensSeen.length, 1);
    });

    test("after 10 minutes it fetches a fresh copy", () async {
      var now = DateTime(2026, 11, 3, 8);
      final net = _Net((t, n, i) => _pdf());
      final svc = _service(net, _Tokens(), cache: TicketCache(clock: () => now));
      await svc.getTicket("SO1");
      now = now.add(const Duration(minutes: 10));
      await svc.getTicket("SO1");
      expect(net.tokensSeen.length, 2);
    });
  });

  group("SADM - Logistique parallel-token picking lists", () {
    test("on a 404 it asks every SADM truck and the first success wins", () async {
      final net = _Net((t, n, i) => t == "truck-b" ? _pdf(<int>[7]) : _notFound);
      final tokens = _Tokens(primary: "logi", name: kLogistique, sadm: <String>["truck-a", "truck-b", "truck-c"]);
      final bytes = await _service(net, tokens).getTicket("SO42");
      expect(bytes, <int>[7]);
      // own token first, then all three SADM trucks; no second try needed.
      expect(net.tokensSeen.first, "logi");
      expect(net.tokensSeen.skip(1).toSet(), <String?>{"truck-a", "truck-b", "truck-c"});
    });

    test("transfers are never fanned out to SADM trucks", () async {
      final net = _Net((t, n, i) => _notFound);
      final tokens = _Tokens(primary: "logi", name: kLogistique, sadm: <String>["truck-a"], toTokens: <String, String>{"TO1": "open-4"});
      await expectLater(_service(net, tokens).getTicket("TO1"), throwsA(isA<TicketException>()));
      expect(net.tokensSeen.contains("truck-a"), isFalse);
      expect(net.tokensSeen, <String?>["open-4", "open-4"]);
    });

    test("a carrier other than Logistique never fans out", () async {
      final net = _Net((t, n, i) => _notFound);
      final tokens = _Tokens(primary: "own", name: "Gat - Sam", sadm: <String>["truck-a"]);
      await expectLater(_service(net, tokens).getTicket("SO1"), throwsA(isA<TicketException>()));
      expect(net.tokensSeen.contains("truck-a"), isFalse);
    });

    test("when every truck also 404s it still retries its own token once, then fails", () async {
      final net = _Net((t, n, i) => _notFound);
      final tokens = _Tokens(primary: "logi", name: kLogistique, sadm: <String>["truck-a", "truck-b"]);
      await expectLater(_service(net, tokens).getTicket("SO1"), throwsA(isA<TicketException>().having((e) => e.status, "status", 404)));
      expect(net.tokensSeen.where((t) => t == "logi").length, 2);
    });
  });

  test("progress is reported: server first, then download", () async {
    final net = _Net((t, n, i) => _pdf());
    final seen = <TicketPhase>[];
    await _service(net, _Tokens()).getTicket("SO1", onProgress: (p, f) => seen.add(p));
    expect(seen.first, TicketPhase.server);
  });

  test("a cached ticket reports an immediate 100% download", () async {
    final net = _Net((t, n, i) => _pdf());
    final svc = _service(net, _Tokens());
    await svc.getTicket("SO1");
    double? fraction;
    await svc.getTicket("SO1", onProgress: (p, f) => fraction = f);
    expect(fraction, 1);
  });
}
