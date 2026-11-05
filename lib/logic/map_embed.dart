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
