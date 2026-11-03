/// A bilingual announcement. English is mandatory, French optional: a missing
/// French title/body falls back to the English one (independently per field).
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    this.titleFr = "",
    this.bodyFr = "",
    this.isActive = true,
    this.createdAt,
    this.images = const <String>[],
  });

  final String id;
  final String title;
  final String body;
  final String titleFr;
  final String bodyFr;
  final bool isActive;
  final DateTime? createdAt;
  final List<String> images;

  String titleFor({required bool french}) => french && titleFr.isNotEmpty ? titleFr : title;
  String bodyFor({required bool french}) => french && bodyFr.isNotEmpty ? bodyFr : body;

  factory Announcement.fromRow(Map<String, dynamic> row, {List<String> images = const <String>[]}) => Announcement(
        id: (row["id"] ?? "").toString(),
        title: (row["title"] ?? "").toString(),
        body: (row["body"] ?? "").toString(),
        titleFr: (row["title_fr"] ?? "").toString(),
        bodyFr: (row["body_fr"] ?? "").toString(),
        isActive: row["is_active"] != false,
        createdAt: DateTime.tryParse((row["created_at"] ?? "").toString()),
        images: images,
      );
}

/// What the editor submits.
class AnnouncementDraft {
  const AnnouncementDraft({required this.title, required this.body, this.titleFr = "", this.bodyFr = ""});
  final String title;
  final String body;
  final String titleFr;
  final String bodyFr;

  static const int maxTitle = 140;
  static const int maxBody = 2000;

  /// English title and body are required (the reference form marks them so).
  bool get isValid => title.trim().isNotEmpty && body.trim().isNotEmpty;

  Map<String, String> toRow() => <String, String>{
        "title": title.trim(),
        "body": body.trim(),
        "title_fr": titleFr.trim(),
        "body_fr": bodyFr.trim(),
      };
}

const String kAnnouncementBucket = "announcement-images";

/// Storage object path inside [bucket] for a public URL, or null if the URL is
/// not one of ours. The path is percent-DECODED: the reference removed the still
/// encoded path, so photos with a space in the name were never actually deleted.
String? storagePathFromUrl(String url, String bucket) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  final m = RegExp("/object/public/${RegExp.escape(bucket)}/(.+)").firstMatch(uri.path);
  if (m == null) return null;
  final raw = m.group(1)!;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

/// Safe object name: ASCII letters, digits, dot, dash, underscore only (a name
/// with spaces/accents/slashes makes URLs fragile). Always ends in .jpg because
/// every upload is re-encoded to JPEG.
String uploadFileName(String originalName) {
  final slash = originalName.lastIndexOf(RegExp(r"[\\/]"));
  var stem = slash >= 0 ? originalName.substring(slash + 1) : originalName;
  final dot = stem.lastIndexOf(".");
  if (dot > 0) stem = stem.substring(0, dot);
  stem = stem.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
  stem = stem.replaceAll(RegExp(r"^\.+"), "");
  if (stem.isEmpty) stem = "photo";
  return "$stem.jpg";
}
