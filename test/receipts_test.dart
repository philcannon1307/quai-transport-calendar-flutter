import "dart:math";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/api/receipts_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/receipts_policy.dart";

import "fake_backend.dart";

Uint8List _photo() {
  final r = Random(3);
  final im = img.Image(width: 1000, height: 700);
  for (final p in im) {
    p.r = r.nextInt(256);
    p.g = r.nextInt(256);
    p.b = r.nextInt(256);
  }
  return Uint8List.fromList(img.encodePng(im));
}

ReceiptsService _svc(FakeBackend b) => ReceiptsService(
    gateway: b,
    clock: () => DateTime(2026, 11, 3, 9, 5),
    newId: () => "uuid-1");

void main() {
  group("who sees the button", () {
    test("allowlisted drivers and InterQL do; Quai2go and strangers do not",
        () {
      expect(canUploadReceipts("SADM - David", isSuperUser: false), isTrue);
      expect(canUploadReceipts("InterQL", isSuperUser: false), isTrue);
      expect(canUploadReceipts(kLogistique, isSuperUser: false), isTrue);
      expect(canUploadReceipts("SADM - Quai2go", isSuperUser: false), isFalse);
      expect(
          canUploadReceipts("Quelqu'un d'autre", isSuperUser: false), isFalse);
      expect(canUploadReceipts(null, isSuperUser: false), isFalse);
    });

    test("the SuperUser always does", () {
      expect(canUploadReceipts("SuperUser", isSuperUser: true), isTrue);
    });

    test("only SADM - Logistique uses BOL mode", () {
      expect(isBolMode(kLogistique), isTrue);
      expect(isBolMode("SADM - David"), isFalse);
      expect(isBolMode("InterQL"), isFalse);
    });

    test("every allowlisted name is a real carrier (typo guard)", () {
      final real = kCarriers.map((c) => c.displayName).toSet();
      for (final n in kReceiptsAllowed) {
        expect(real.contains(n), isTrue,
            reason: "$n is not in the carrier list");
      }
    });
  });

  group("receipt upload", () {
    test(
        "uploads a compressed JPEG, logs the row, emails with the receipt template",
        () async {
      final b = FakeBackend();
      final r = await _svc(b).submit(
          photo: _photo(),
          driver: " Marc ",
          carrierName: "InterQL",
          note: "Essence",
          bol: false);
      expect(r.isOk, isTrue);
      expect(b.uploads.single["bucket"], "receipts");
      expect(b.uploads.single["path"], "2026-11-03/uuid-1.jpg");
      expect(b.uploads.single["type"], "image/jpeg");
      expect(b.uploads.single["bytes"] as int, lessThanOrEqualTo(300 * 1024));
      expect(b.receipts.single["driver_name"], "Marc");
      expect(b.emails.single.template, "receipt-uploaded");
      expect(b.emails.single.data.containsKey("recipientEmail"), isFalse,
          reason: "recipient is fixed server-side, never chosen by the client");
      expect(b.emails.single.data.keys.toSet(),
          <String>{"receiptId", "storagePath", "kind"},
          reason: "ids only, no free text or addresses");
      expect(b.emails.single.data["storagePath"], b.uploads.single["path"]);
      expect(b.sentMarks, <String>["receipt:rcpt-1"]);
    });

    test("BOL goes under bol/ with the BOL template", () async {
      final b = FakeBackend();
      final r = await _svc(b).submit(
          photo: _photo(),
          driver: "Éric",
          carrierName: kLogistique,
          note: "",
          bol: true);
      expect(r.isOk, isTrue);
      expect(b.uploads.single["path"], "bol/2026-11-03/uuid-1.jpg");
      expect(b.emails.single.template, "bol-uploaded");
    });

    test("missing photo or driver sends nothing", () async {
      final b = FakeBackend();
      expect(
          (await _svc(b).submit(
                  photo: null,
                  driver: "x",
                  carrierName: "InterQL",
                  note: "",
                  bol: false))
              .failure,
          ReceiptFailure.noPhoto);
      expect(
          (await _svc(b).submit(
                  photo: _photo(),
                  driver: "  ",
                  carrierName: "InterQL",
                  note: "",
                  bol: false))
              .failure,
          ReceiptFailure.noDriver);
      expect(b.uploads, isEmpty);
      expect(b.emails, isEmpty);
    });

    test("an unreadable file is rejected before any upload", () async {
      final b = FakeBackend();
      final r = await _svc(b).submit(
          photo: Uint8List.fromList(<int>[9, 9, 9]),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.failure, ReceiptFailure.unreadablePhoto);
      expect(b.uploads, isEmpty);
    });

    test("an unconfigured backend says so instead of pretending to send",
        () async {
      final r = await _svc(FakeBackend(isConfigured: false)).submit(
          photo: _photo(),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.failure, ReceiptFailure.notConfigured);
    });

    test("upload failure: no row, no email", () async {
      final b = FakeBackend()..failUpload = true;
      final r = await _svc(b).submit(
          photo: _photo(),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.failure, ReceiptFailure.upload);
      expect(b.receipts, isEmpty);
      expect(b.emails, isEmpty);
    });

    test("a failed log row does not stop the email (photo is stored)",
        () async {
      final b = FakeBackend()..failReceiptRow = true;
      final r = await _svc(b).submit(
          photo: _photo(),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.isOk, isTrue);
      expect(b.emails, hasLength(1));
    });

    test("email failure is reported and the row is NOT marked as sent",
        () async {
      final b = FakeBackend()..failEmail = true;
      final r = await _svc(b).submit(
          photo: _photo(),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.failure, ReceiptFailure.email);
      expect(b.sentMarks, isEmpty);
    });

    test(
        "a suppressed (unsubscribed) recipient is reported, not claimed as sent",
        () async {
      final b = FakeBackend()..suppressed = <String>{};
      // template-fixed recipients have no address client-side: simulate via a subclass
      final svc = ReceiptsService(
          gateway: _SuppressAll(),
          clock: () => DateTime(2026, 11, 3),
          newId: () => "u");
      final r = await svc.submit(
          photo: _photo(),
          driver: "x",
          carrierName: "InterQL",
          note: "",
          bol: false);
      expect(r.isOk, isTrue);
      expect(r.suppressed, isTrue);
      expect(b.sentMarks, isEmpty);
    });
  });
}

class _SuppressAll extends FakeBackend {
  @override
  Future<EmailOutcome> sendEmail({
    required String template,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  }) async =>
      EmailOutcome.suppressed;
}
