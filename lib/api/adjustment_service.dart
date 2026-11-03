import "dart:typed_data";

import "../data/carriers.dart";
import "../logic/adjustment.dart";
import "../logic/announcements.dart" show uploadFileName;
import "../logic/ids.dart";
import "../logic/image_compress.dart";
import "backend_gateway.dart";

enum AdjustmentFailure { noItems, unreadablePhoto, notConfigured, photoUpload, badRecipient, email }

class AdjustmentResult {
  const AdjustmentResult.ok({this.suppressedCount = 0}) : failure = null;
  const AdjustmentResult.failed(AdjustmentFailure this.failure) : suppressedCount = 0;

  final AdjustmentFailure? failure;

  /// Recipients that had unsubscribed and therefore received nothing.
  final int suppressedCount;

  bool get isOk => failure == null;
}

/// On-site change report ("Signaler un changement") for a sales or transfer
/// order: logged, then emailed to the right branch inbox(es).
///
/// Routing is `adjustmentRecipients` (group inbox; transfers go to BOTH stores).
class AdjustmentService {
  AdjustmentService({required this.gateway, DateTime Function()? clock, String Function()? newId})
      : _clock = clock ?? DateTime.now,
        _newId = newId ?? newUuid4;

  final BackendGateway gateway;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// [reportId] is created ONCE per form and reused on retry. Both the log row
  /// and every email idempotency key derive from it, so retrying after a partial
  /// failure cannot send the same report twice (the reference minted a new id
  /// per attempt and could duplicate emails).
  Future<AdjustmentResult> submit({
    required String reportId,
    required String orderNum,
    required String carrierName,
    required String reporterName,
    required List<AdjustmentRow> rows,
    required String note,
    Uint8List? photo,
    String photoName = "photo.jpg",
    List<String> transferLocations = const <String>[],
  }) async {
    final items = filledRows(rows);
    if (items.isEmpty) return const AdjustmentResult.failed(AdjustmentFailure.noItems);
    if (!gateway.configured) return const AdjustmentResult.failed(AdjustmentFailure.notConfigured);

    final kind = adjustmentKind(orderNum);
    final recipients = adjustmentRecipients(carrierName, kind == "TO" ? transferLocations : const <String>[]);
    if (recipients.isEmpty || !recipients.every(isGroupeQlAddress)) {
      return const AdjustmentResult.failed(AdjustmentFailure.badRecipient);
    }

    final now = _clock();

    // Photo first, so no email ever points at a picture that failed to upload.
    String? photoUrl;
    if (photo != null) {
      final CompressedImage image;
      try {
        image = compressForUpload(photo);
      } on ImageCompressException {
        return const AdjustmentResult.failed(AdjustmentFailure.unreadablePhoto);
      }
      final path = "adjustments/${isoDate(now)}/${_newId()}-${uploadFileName(photoName)}";
      try {
        photoUrl = await gateway.uploadFile(
          bucket: "receipts",
          path: path,
          bytes: image.bytes,
          contentType: image.mimeType,
        );
      } on BackendException {
        return const AdjustmentResult.failed(AdjustmentFailure.photoUpload);
      }
    }

    var rowLogged = true;
    try {
      await gateway.insertAdjustment(<String, dynamic>{
        "id": reportId,
        "order_num": orderNum,
        "order_kind": kind,
        "carrier_name": carrierName,
        "reporter_name": reporterName.trim(),
        "items": items.map((r) => r.toJson()).toList(),
        "note": note.trim(),
        "photo_url": photoUrl,
      });
    } on BackendException catch (e) {
      // 409 = this report was already logged on an earlier attempt: fine.
      rowLogged = e.status == 409;
    }

    var suppressed = 0;
    try {
      for (final recipient in recipients) {
        final outcome = await gateway.sendEmail(
          template: "order-adjustment",
          recipient: recipient,
          idempotencyKey: "adjustment-$reportId-$recipient",
          data: <String, dynamic>{
            "orderNum": orderNum,
            "orderKind": kind,
            "carrierName": carrierName,
            "reporterName": reporterName.trim(),
            "items": items.map((r) => r.toJson()).toList(),
            "note": note.trim(),
            "photoUrl": photoUrl,
            "reportedAt": stamp(now),
          },
        );
        if (outcome == EmailOutcome.suppressed) suppressed++;
      }
    } on BackendException {
      return const AdjustmentResult.failed(AdjustmentFailure.email);
    }

    if (rowLogged && suppressed < recipients.length) {
      try {
        await gateway.markAdjustmentEmailSent(reportId);
      } on BackendException {
        // bookkeeping only
      }
    }
    return AdjustmentResult.ok(suppressedCount: suppressed);
  }
}
