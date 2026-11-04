import "dart:convert";

import "../logic/contact_parser.dart";
import "../state/session_store_port.dart";
import "concurrency_limiter.dart";

/// Reads the first page of a PDF as text lines. The real implementation
/// (pdfrx) lives in lib/pdf/pdfrx_impl.dart so tests never load a PDF engine.
abstract class PdfTextExtractor {
  Future<List<String>?> firstPageLines(List<int> pdfBytes);
}

class UnavailablePdfTextExtractor implements PdfTextExtractor {
  const UnavailablePdfTextExtractor();
  @override
  Future<List<String>?> firstPageLines(List<int> pdfBytes) async => null;
}

/// Ship-to phone + address, read from the picking-ticket PDF.
/// Ported from orderContact.ts: cached per order, concurrent requests for the
/// same order share one extraction, at most [maxConcurrent] PDFs are processed
/// at once, and a failure yields null instead of an error.
class ContactService {
  ContactService({
    required this.fetchTicket,
    required this.extractor,
    required this.store,
    ConcurrencyLimiter? limiter,
  }) : limiter = limiter ?? ConcurrencyLimiter(maxConcurrent);

  static const int maxConcurrent = 2;
  static const String keyPrefix = "quai:contact:v1:";

  final Future<List<int>> Function(String orderNum) fetchTicket;
  final PdfTextExtractor extractor;
  final KeyValueStore store;
  final ConcurrencyLimiter limiter;
  final Map<String, Future<OrderContact?>> _pending =
      <String, Future<OrderContact?>>{};

  Future<OrderContact?> contactFor(String soNum) {
    final cached = store.read("$keyPrefix$soNum");
    if (cached != null) {
      try {
        return Future<OrderContact?>.value(
            OrderContact.fromJson(jsonDecode(cached) as Map<String, dynamic>));
      } catch (_) {
        // corrupt cache entry: fall through and re-extract
      }
    }
    final inFlight = _pending[soNum];
    if (inFlight != null) return inFlight;
    final f = _load(soNum);
    _pending[soNum] = f;
    f.whenComplete(() => _pending.remove(soNum));
    return f;
  }

  Future<OrderContact?> _load(String soNum) async {
    try {
      final contact = await limiter.run<OrderContact?>(() => _extract(soNum));
      if (contact != null && !contact.isEmpty) {
        store.write("$keyPrefix$soNum", contact.encode());
      }
      return contact;
    } catch (_) {
      return null;
    }
  }

  Future<OrderContact?> _extract(String soNum) async {
    final bytes = await fetchTicket(soNum);
    final lines = await extractor.firstPageLines(bytes);
    if (lines == null) return null;
    return parseContact(lines, soNum);
  }
}
