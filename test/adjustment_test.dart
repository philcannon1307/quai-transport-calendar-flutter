import "dart:math";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:quai_calendar/api/adjustment_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/adjustment.dart";

import "fake_backend.dart";

AdjustmentService _svc(FakeBackend b) =>
    AdjustmentService(gateway: b, clock: () => DateTime(2026, 11, 3, 14, 30), newId: () => "pic");

const _rows = <AdjustmentRow>[
  AdjustmentRow(item: " Panneau 4x8 ", from: "10", to: "8", reason: "cassés"),
  AdjustmentRow(item: "", from: "1", to: "2"), // blank item: dropped
];

Uint8List _photo() {
  final r = Random(5);
  final im = img.Image(width: 600, height: 400);
  for (final p in im) {
    p.r = r.nextInt(256);
  }
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  group("pure helpers", () {
    test("TO vs SO", () {
      expect(adjustmentKind("TO2599"), "TO");
      expect(adjustmentKind("to2599"), "TO");
      expect(adjustmentKind("SO12345"), "SO");
    });

    test("blank rows are dropped and the rest trimmed", () {
      final f = filledRows(_rows);
      expect(f, hasLength(1));
      expect(f.single.item, "Panneau 4x8");
    });

    test("only groupeql.com addresses are allowed", () {
      expect(isGroupeQlAddress("sadm@groupeql.com"), isTrue);
      expect(isGroupeQlAddress(" SADM@GroupeQL.com "), isTrue);
      expect(isGroupeQlAddress("evil@gmail.com"), isFalse);
      expect(isGroupeQlAddress("a@groupeql.com.evil.io"), isFalse);
      expect(isGroupeQlAddress("x@evilgroupeql.com"), isFalse);
      expect(isGroupeQlAddress(""), isFalse);
    });

    test("every inbox the routing table can return is a groupeql.com address", () {
      for (final c in kCarriers) {
        for (final r in adjustmentRecipients(c.displayName)) {
          expect(isGroupeQlAddress(r), isTrue, reason: "${c.displayName} -> $r");
        }
      }
    });
  });

  group("submission", () {
    test("a sales order goes to the carrier's group inbox, once", () async {
      final b = FakeBackend();
      final r = await _svc(b).submit(
        reportId: "rep-1",
        orderNum: "SO100",
        carrierName: "SADM - David",
        reporterName: " David ",
        rows: _rows,
        note: " n ",
      );
      expect(r.isOk, isTrue);
      expect(b.adjustments.single["id"], "rep-1");
      expect(b.adjustments.single["order_kind"], "SO");
      expect((b.adjustments.single["items"] as List), hasLength(1));
      expect(b.emails, hasLength(1));
      expect(b.emails.single.template, "order-adjustment");
      expect(b.emails.single.recipient, adjustmentRecipients("SADM - David").single);
      expect(b.emails.single.key, startsWith("adjustment-rep-1-"));
      expect(b.sentMarks, <String>["adjustment:rep-1"]);
    });

    test("a transfer order is emailed to BOTH stores", () async {
      final b = FakeBackend();
      final locs = <String>["Ste-Agathe", "Gatineau"];
      final expected = adjustmentRecipients("SADM - Logistique", locs);
      final r = await _svc(b).submit(
        reportId: "rep-2",
        orderNum: "TO2599",
        carrierName: "SADM - Logistique",
        reporterName: "x",
        rows: _rows,
        note: "",
        transferLocations: locs,
      );
      expect(r.isOk, isTrue);
      expect(b.emails.map((e) => e.recipient).toList(), expected);
      expect(b.emails.map((e) => e.key).toSet(), hasLength(b.emails.length), reason: "one idempotency key per recipient");
    });

    test("no filled rows: nothing is sent", () async {
      final b = FakeBackend();
      final r = await _svc(b).submit(
        reportId: "r", orderNum: "SO1", carrierName: "InterQL", reporterName: "x",
        rows: const <AdjustmentRow>[AdjustmentRow(item: "  ")], note: "",
      );
      expect(r.failure, AdjustmentFailure.noItems);
      expect(b.emails, isEmpty);
      expect(b.adjustments, isEmpty);
    });

    test("photo is uploaded first; a failed upload sends no email", () async {
      final b = FakeBackend()..failUpload = true;
      final r = await _svc(b).submit(
        reportId: "r", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "", photo: _photo(),
      );
      expect(r.failure, AdjustmentFailure.photoUpload);
      expect(b.emails, isEmpty);
      expect(b.adjustments, isEmpty);
    });

    test("the photo URL travels in the row and the email", () async {
      final b = FakeBackend();
      await _svc(b).submit(
        reportId: "r", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "", photo: _photo(), photoName: "Ma photo é.png",
      );
      final path = b.uploads.single["path"] as String;
      expect(path, "adjustments/2026-11-03/pic-Ma_photo__.jpg");
      expect(b.adjustments.single["photo_url"], contains(path));
      expect(b.emails.single.data["photoUrl"], contains(path));
    });

    test("RETRY: a 409 on the log row (already logged) still sends the email with the SAME keys", () async {
      final b = FakeBackend()
        ..failAdjustmentRow = true
        ..adjustmentRowStatus = 409;
      final r = await _svc(b).submit(reportId: "same", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "");
      expect(r.isOk, isTrue);
      expect(b.emails, hasLength(1));
      expect(b.emails.single.key, contains("same"));
      expect(b.sentMarks, isNotEmpty);
    });

    test("a failed log row (not a duplicate) does not claim the email was recorded", () async {
      final b = FakeBackend()..failAdjustmentRow = true;
      final r = await _svc(b).submit(reportId: "x", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "");
      expect(r.isOk, isTrue, reason: "the email still goes out");
      expect(b.sentMarks, isEmpty, reason: "but the row cannot be marked sent");
    });

    test("email failure is reported", () async {
      final b = FakeBackend()..failEmail = true;
      final r = await _svc(b).submit(reportId: "x", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "");
      expect(r.failure, AdjustmentFailure.email);
    });

    test("an unsubscribed recipient is counted, not hidden", () async {
      final b = FakeBackend();
      b.suppressed = adjustmentRecipients("InterQL").toSet();
      final r = await _svc(b).submit(reportId: "x", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "");
      expect(r.isOk, isTrue);
      expect(r.suppressedCount, 1);
      expect(b.sentMarks, isEmpty, reason: "nobody was actually notified");
    });

    test("unconfigured backend", () async {
      final r = await _svc(FakeBackend(isConfigured: false))
          .submit(reportId: "x", orderNum: "SO1", carrierName: "InterQL", reporterName: "x", rows: _rows, note: "");
      expect(r.failure, AdjustmentFailure.notConfigured);
    });
  });
}
