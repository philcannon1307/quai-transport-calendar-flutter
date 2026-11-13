/// Embedded-map helpers (pure Dart, unit-testable).

/// Maps Embed API key, supplied at BUILD time (--dart-define=QUAI_MAPS_EMBED_KEY=...). Never committed.
const String kMapsEmbedKey = String.fromEnvironment("QUAI_MAPS_EMBED_KEY");

/// The address as the map query, or null when it is missing / unusable (no letters, or too short to locate anything).
String? mapQueryFor(String? address) {
  final a = (address ?? "").replaceAll(RegExp(r"\s+"), " ").trim();
  if (a.length < 6) return null;
  if (!RegExp(r"[A-Za-zÀ-ÿ]{3}").hasMatch(a)) return null;
  return a;
}

/// Iframe URL: the official Maps Embed API when a key is configured, else the keyless (unofficial) embed.
String mapEmbedUrl(String query, {String key = kMapsEmbedKey}) {
  final q = Uri.encodeComponent(query);
  final k = key.trim();
  return k.isEmpty
      ? "https://maps.google.com/maps?q=$q&output=embed"
      : "https://www.google.com/maps/embed/v1/place?key=${Uri.encodeComponent(k)}&q=$q";
}

final RegExp _phoneRe = RegExp(r"(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}");
final RegExp _noteLabelRe = RegExp(
    r"\b(?:adresse|address)\s+(?:du\s+|de\s+la\s+|d['’]\s*)?voisin(?:e)?\s*:?\s*|\bchez\s+(?:le|la)\s+voisin(?:e)?\s*:?\s*|\bneighbou?r(?:'s)?\s+address\s*:?\s*",
    caseSensitive: false);
final RegExp _provinceRe = RegExp(
    r"\b(?:QC|Qc|Qu[eé]bec|ON|Ontario|NB|NS|PE|MB|SK|AB|BC|NL)\b");
final RegExp _postalRe =
    RegExp(r"\b[A-Za-z]\d[A-Za-z][\s\-]?\d[A-Za-z]\d\b");

/// Map query for the CUSTOMER's full address (street + city + province [+ postal code] + country).
///
/// [ticketAddress] is the free-text address read from the picking ticket; it may carry a phone number or a
/// "Adresse voisin" note label that must not reach the geocoder (it made the pin land on a business ~100 km away).
/// [street]/[city]/[province]/[postal] come from the order record and complete what the ticket lacks.
/// Province defaults to Québec and the country to Canada. Returns null when nothing locatable remains.
String? customerMapQuery({
  String? ticketAddress,
  String? street,
  String? city,
  String? province,
  String? postal,
  String country = "Canada",
}) {
  String clean(String? v) {
    var t = (v ?? "").replaceAll(_noteLabelRe, " ").replaceAll(_phoneRe, " ");
    t = t.replaceAll(RegExp(r"\b(?:t[eé]l[eé]phone|phone|t[eé]l|cell)\s*\.?\s*:?", caseSensitive: false), " ");
    return t.replaceAll(RegExp(r"\s+"), " ").replaceAll(RegExp(r"^[\s,;:\-]+|[\s,;:\-]+$"), "").trim();
  }

  final parts = <String>[];
  void add(String? raw) {
    for (final seg in (raw ?? "").split(RegExp(r"[,\n]"))) {
      final t = clean(seg);
      if (t.isEmpty) continue;
      final low = t.toLowerCase();
      if (parts.any((e) => e.toLowerCase() == low || e.toLowerCase().contains(low))) continue;
      parts.add(t);
    }
  }

  add((ticketAddress ?? "").trim().isNotEmpty ? ticketAddress : street);
  final base = parts.join(", ");
  if (mapQueryFor(base) == null) return null;
  final hasCity = (city ?? "").trim().isEmpty || base.toLowerCase().contains(city!.trim().toLowerCase());
  if (!hasCity) add(city);
  if (!_provinceRe.hasMatch(parts.join(", "))) add((province ?? "").trim().isEmpty ? "QC" : province);
  if (!_postalRe.hasMatch(parts.join(", "))) add(postal);
  final out = parts.join(", ");
  return mapQueryFor(out.toLowerCase().contains(country.toLowerCase()) ? out : "$out, $country");
}
