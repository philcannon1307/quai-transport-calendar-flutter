import "dart:math";

/// RFC 4122 version-4 UUID. No package: Postgres uuid columns accept this, and
/// the only requirement is that it is unique and well-formed.
String newUuid4({Random? random}) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int from, int to) => b
      .sublist(from, to)
      .map((x) => x.toRadixString(16).padLeft(2, "0"))
      .join();
  return "${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}";
}

/// Local calendar date as YYYY-MM-DD.
String isoDate(DateTime d) =>
    "${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";

/// "2026-11-03 08:15" in local time, for the email body.
String stamp(DateTime d) =>
    "${isoDate(d)} ${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
