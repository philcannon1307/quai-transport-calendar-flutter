import "dart:math";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:quai_calendar/api/announcements_service.dart";
import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/api/unsubscribe_service.dart";
import "package:quai_calendar/logic/announcements.dart";

import "fake_backend.dart";

Uint8List _png() {
  final r = Random(2);
  final im = img.Image(width: 500, height: 300);
  for (final p in im) {
    p.g = r.nextInt(256);
  }
  return Uint8List.fromList(img.encodePng(im));
}

const _bucket = "announcement-images";

void main() {
  group("bilingual fallback", () {
    const a = Announcement(
        id: "1", title: "Hello", body: "World", titleFr: "", bodyFr: "Monde");
    test("French falls back to English per field", () {
      expect(a.titleFor(french: true), "Hello");
      expect(a.bodyFor(french: true), "Monde");
      expect(a.titleFor(french: false), "Hello");
      expect(a.bodyFor(french: false), "World");
    });
  });

  group("draft validation", () {
    test("English title and body are required, French is optional", () {
      expect(const AnnouncementDraft(title: "t", body: "b").isValid, isTrue);
      expect(const AnnouncementDraft(title: " ", body: "b").isValid, isFalse);
      expect(const AnnouncementDraft(title: "t", body: "").isValid, isFalse);
    });
  });

  group("storage paths", () {
    String url(String p) =>
        "https://x.supabase.co/storage/v1/object/public/$_bucket/$p";
    test("a plain URL maps to its object path", () {
      expect(storagePathFromUrl(url("abc/123-photo.jpg"), _bucket),
          "abc/123-photo.jpg");
    });
    test(
        "percent-encoding is DECODED (the reference left it encoded and never deleted such files)",
        () {
      expect(storagePathFromUrl(url("abc/my%20photo.jpg"), _bucket),
          "abc/my photo.jpg");
    });
    test("a foreign URL is not ours", () {
      expect(storagePathFromUrl("https://evil.test/a.jpg", _bucket), isNull);
      expect(storagePathFromUrl(url("a.jpg"), "other-bucket"), isNull);
    });
    test("upload names are ASCII-safe and always .jpg", () {
      expect(uploadFileName("Ma photo é.PNG"), "Ma_photo__.jpg");
      expect(uploadFileName("C:\\x\\y\\site.jpeg"), "site.jpg");
      expect(uploadFileName("...."), "photo.jpg");
      expect(uploadFileName(""), "photo.jpg");
    });
  });

  group("saving", () {
    AnnouncementsService svc(FakeBackend b) => AnnouncementsService(
        gateway: b, clock: () => DateTime.fromMillisecondsSinceEpoch(1000));

    test("create: row, then compressed photos under <id>/", () async {
      final b = FakeBackend();
      final r = await svc(b).save(
        draft: const AnnouncementDraft(
            title: "T", body: "B", titleFr: "TF", bodyFr: "BF"),
        newPhotos: <NewPhoto>[NewPhoto(_png(), "a b.png")],
      );
      expect(r.isOk, isTrue);
      expect(b.insertedAnnouncements.single, <String, String>{
        "title": "T",
        "body": "B",
        "title_fr": "TF",
        "body_fr": "BF"
      });
      expect(b.uploads.single["bucket"], _bucket);
      expect(b.uploads.single["path"], "ann-1/1000-a_b.jpg");
      expect(b.insertedImages, hasLength(1));
    });

    test("invalid draft writes nothing", () async {
      final b = FakeBackend();
      final r = await svc(b)
          .save(draft: const AnnouncementDraft(title: "", body: ""));
      expect(r.failure, AnnouncementFailure.invalid);
      expect(b.insertedAnnouncements, isEmpty);
    });

    test("a photo that fails does not lose the announcement; it is counted",
        () async {
      final b = FakeBackend()..failUpload = true;
      final r = await svc(b).save(
        draft: const AnnouncementDraft(title: "T", body: "B"),
        newPhotos: <NewPhoto>[
          NewPhoto(_png(), "a.png"),
          NewPhoto(Uint8List.fromList(<int>[1, 2]), "bad.png")
        ],
      );
      expect(r.isOk, isTrue);
      expect(r.photosFailed, 2);
      expect(b.insertedAnnouncements, hasLength(1));
    });

    test(
        "removing a photo deletes the file by DECODED path and the row, even if the file removal fails",
        () async {
      final b = FakeBackend()..failRemoveFiles = true;
      const u =
          "https://x.supabase.co/storage/v1/object/public/$_bucket/ann-1/my%20photo.jpg";
      const existing =
          Announcement(id: "ann-1", title: "T", body: "B", images: <String>[u]);
      final r = await svc(b).save(
          draft: const AnnouncementDraft(title: "T", body: "B"),
          existing: existing,
          removedUrls: <String>[u]);
      expect(r.isOk, isTrue);
      expect(b.deletedImageUrls, <String>[u],
          reason: "row removed so no broken image remains");
    });

    test("delete removes files then the announcement", () async {
      final b = FakeBackend();
      const u =
          "https://x.supabase.co/storage/v1/object/public/$_bucket/ann-1/p.jpg";
      final ok = await svc(b).delete(const Announcement(
          id: "ann-1", title: "T", body: "B", images: <String>[u]));
      expect(ok, isTrue);
      expect(b.removed, <String>["ann-1/p.jpg"]);
      expect(b.deletedAnnouncements, <String>["ann-1"]);
    });

    test("unconfigured backend refuses to save instead of pretending",
        () async {
      final r = await svc(FakeBackend(isConfigured: false))
          .save(draft: const AnnouncementDraft(title: "T", body: "B"));
      expect(r.failure, AnnouncementFailure.notConfigured);
    });
  });

  group("unsubscribe", () {
    test("token is read from the hash route or from the page URL", () {
      expect(
          unsubscribeToken(
              routeName: "/unsubscribe?token=abc",
              pageUri: Uri.parse("https://h.test/")),
          "abc");
      expect(
          unsubscribeToken(
              routeName: "/unsubscribe",
              pageUri: Uri.parse("https://h.test/?token=xyz#/unsubscribe")),
          "xyz");
      expect(
          unsubscribeToken(
              routeName: "/unsubscribe", pageUri: Uri.parse("https://h.test/")),
          isNull);
      expect(
          unsubscribeToken(
              routeName: "/unsubscribe?token=",
              pageUri: Uri.parse("https://h.test/")),
          isNull);
    });

    test("no token is invalid without calling the server", () async {
      final b = FakeBackend();
      expect(await UnsubscribeService(gateway: b).check(null),
          UnsubscribeCheck.invalid);
    });

    test("valid, already-unsubscribed and confirm map straight through",
        () async {
      final b = FakeBackend();
      final s = UnsubscribeService(gateway: b);
      expect(await s.check("t"), UnsubscribeCheck.valid);
      b.checkResult = UnsubscribeCheck.alreadyUnsubscribed;
      expect(await s.check("t"), UnsubscribeCheck.alreadyUnsubscribed);
      expect(await s.confirm("t"), UnsubscribeResult.done);
    });

    test("an unconfigured backend never claims success", () async {
      expect(
          await UnsubscribeService(gateway: FakeBackend(isConfigured: false))
              .check("t"),
          UnsubscribeCheck.invalid);
    });
  });
}
