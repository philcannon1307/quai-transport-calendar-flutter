import "dart:typed_data";

import "../logic/ids.dart";
import "../logic/image_compress.dart";
import "../logic/receipts_policy.dart";
import "backend_gateway.dart";

enum ReceiptFailure {
  noPhoto,
  noDriver,
  unreadablePhoto,
  notConfigured,
  upload,
  email
}

class ReceiptResult {
  const ReceiptResult.ok({this.suppressed = false}) : failure = null;
  const ReceiptResult.failed(ReceiptFailure this.failure) : suppressed = false;

  final ReceiptFailure? failure;

  /// The email was NOT sent because the recipient unsubscribed. The photo is
  /// stored and logged, but nobody was notified.
  final bool suppressed;

  bool get isOk => failure == null;
}

/// Receipt (REÇU) and bill-of-lading (BOL) upload:
/// compress -> store in the `receipts` bucket -> log the row -> email.
///
/// The email RECIPIENT is never chosen here: the server-side templates are
/// fixed to comptabilite@groupeql.com (receipt) and sadm@groupeql.com (BOL).
class ReceiptsService {
  ReceiptsService(
      {required this.gateway,
      DateTime Function()? clock,
      String Function()? newId})
      : _clock = clock ?? DateTime.now,
        _newId = newId ?? newUuid4;

  final BackendGateway gateway;
  final DateTime Function() _clock;
  final String Function() _newId;

  static const String bucket = "receipts";

  Future<ReceiptResult> submit({
    required Uint8List? photo,
    required String driver,
    required String carrierName,
    required String note,
    required bool bol,
  }) async {
    if (photo == null)
      return const ReceiptResult.failed(ReceiptFailure.noPhoto);
    if (driver.trim().isEmpty)
      return const ReceiptResult.failed(ReceiptFailure.noDriver);
    if (!gateway.configured)
      return const ReceiptResult.failed(ReceiptFailure.notConfigured);

    final CompressedImage image;
    try {
      image = compressForUpload(photo);
    } on ImageCompressException {
      return const ReceiptResult.failed(ReceiptFailure.unreadablePhoto);
    }

    final now = _clock();
    final path =
        "${bol ? "bol/" : ""}${isoDate(now)}/${_newId()}.${image.extension}";
    final String publicUrl;
    try {
      publicUrl = await gateway.uploadFile(
        bucket: bucket,
        path: path,
        bytes: image.bytes,
        contentType: image.mimeType,
      );
    } on BackendException {
      return const ReceiptResult.failed(ReceiptFailure.upload);
    }

    String? rowId;
    try {
      rowId = await gateway.insertReceipt(<String, dynamic>{
        "driver_name": driver.trim(),
        "carrier_name": carrierName,
        "note": note.trim(),
        "storage_path": path,
        "public_url": publicUrl,
      });
    } on BackendException {
      // The log row is bookkeeping; the photo is stored, so still send the email.
      rowId = null;
    }

    final EmailOutcome outcome;
    try {
      outcome = await gateway.sendEmail(
        template: receiptTemplateName(bol: bol),
        idempotencyKey: "${bol ? "bol" : "receipt"}-${rowId ?? path}",
        // Ids only: the server reads the receipt row / storage object itself and
        // fixes the recipient by template (receipt -> accounting, BOL -> SADM).
        data: <String, dynamic>{
          "receiptId": rowId,
          "storagePath": path,
          "kind": bol ? "bol" : "receipt",
        },
      );
    } on BackendException {
      return const ReceiptResult.failed(ReceiptFailure.email);
    }

    if (outcome == EmailOutcome.sent && rowId != null) {
      try {
        await gateway.markReceiptEmailSent(rowId);
      } on BackendException {
        // bookkeeping only
      }
    }
    return ReceiptResult.ok(suppressed: outcome == EmailOutcome.suppressed);
  }
}
