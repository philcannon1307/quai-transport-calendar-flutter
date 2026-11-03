import "dart:typed_data";

import "../data/carriers.dart";
import "../logic/adjustment.dart";
import "../logic/announcements.dart" show uploadFileName;
import "../logic/ids.dart";
import "../logic/image_compress.dart";
import "backend_gateway.dart";

enum AdjustmentFailure { noItems, unreadablePhoto, notConfigured, photoUpload, badRecipient, log, email }

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
        // Transfers: the server reads the stores from this column and emails both of them.
        // Only our fixed store inboxes can ever result from it; unknown names are ignored.
        "transfer_locations": kind == "TO" ? transferLocations : null,
      });
    } on BackendException catch (e) {
      // 409 = this report was already logged on an earlier attempt: fine.
      rowLogged = e.status == 409;
    }
    // The server builds the email FROM the logged row, so without a row there is
    // nothing to send. Fail visibly; the same reportId makes the retry safe.
    if (!rowLogged) return const AdjustmentResult.failed(AdjustmentFailure.log);

    // The client sends ONLY ids. The server looks the report up, derives the
    // recipients (group inbox; transfers go to both stores) from the verified
    // sender and the order, and rejects anything that is not a groupeql.com mailbox.
    var suppressed = 0;
    try {
      final outcome = await gateway.sendEmail(
        template: "order-adjustment",
        idempotencyKey: "adjustment-$reportId",
        data: <String, dynamic>{"reportId": reportId, "orderNum": orderNum},
      );
      if (outcome == EmailOutcome.suppressed) suppressed = 1;
    } on BackendException {
      return const AdjustmentResult.failed(AdjustmentFailure.email);
    }

    if (suppressed == 0) {
      try {
        await gateway.markAdjustmentEmailSent(reportId);
      } on BackendException {
        // bookkeeping only
      }
    }
    return AdjustmentResult.ok(suppressedCount: suppressed);
  }
}
