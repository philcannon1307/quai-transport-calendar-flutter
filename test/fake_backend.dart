import "dart:typed_data";

import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/logic/announcements.dart";

class SentEmail {
  SentEmail(this.template, this.key, this.data);
  final String template;
  final String key;
  final Map<String, dynamic> data;
}

/// In-memory BackendGateway that records every call.
class FakeBackend implements BackendGateway {
  FakeBackend({this.isConfigured = true});
  final bool isConfigured;

  // failure switches
  bool failUpload = false;
  bool failEmail = false;
  bool failReceiptRow = false;
  bool failAdjustmentRow = false;
  int adjustmentRowStatus = 500;
  bool failRemoveFiles = false;
  Set<String> suppressed = <String>{};
  bool suppressAll = false;

  final List<SentEmail> emails = <SentEmail>[];
  final List<Map<String, dynamic>> uploads = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> receipts = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> adjustments = <Map<String, dynamic>>[];
  final List<String> sentMarks = <String>[];
  final List<List<Map<String, dynamic>>> historyUpserts =
      <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>> historyToReturn = <Map<String, dynamic>>[];
  final List<Map<String, String>> historyQueries = <Map<String, String>>[];
  final List<String> removed = <String>[];
  final List<String> deletedImageUrls = <String>[];
  final List<String> deletedAnnouncements = <String>[];
  final List<Map<String, String>> insertedAnnouncements =
      <Map<String, String>>[];
  final List<String> insertedImages = <String>[];
  UnsubscribeCheck checkResult = UnsubscribeCheck.valid;
  UnsubscribeResult confirmResult = UnsubscribeResult.done;

  @override
  bool get configured => isConfigured;

  @override
  Future<List<Announcement>> activeAnnouncements() async => <Announcement>[];
  @override
  Future<String> insertAnnouncement(Map<String, String> row) async {
    insertedAnnouncements.add(row);
    return "ann-1";
  }

  @override
  Future<void> updateAnnouncement(String id, Map<String, String> row) async {}
  @override
  Future<void> deleteAnnouncement(String id) async =>
      deletedAnnouncements.add(id);
  @override
  Future<void> insertAnnouncementImage(
          String announcementId, String url) async =>
      insertedImages.add(url);
  @override
  Future<void> deleteAnnouncementImageByUrl(String url) async =>
      deletedImageUrls.add(url);

  @override
  String publicUrl(String bucket, String path) =>
      "https://x.test/storage/v1/object/public/$bucket/$path";

  @override
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    if (failUpload) throw const BackendException(500, "upload failed");
    uploads.add(<String, dynamic>{
      "bucket": bucket,
      "path": path,
      "bytes": bytes.length,
      "type": contentType
    });
    return publicUrl(bucket, path);
  }

  @override
  Future<void> removeFiles(String bucket, List<String> paths) async {
    if (failRemoveFiles) throw const BackendException(500, "remove failed");
    removed.addAll(paths);
  }

  @override
  Future<String?> insertReceipt(Map<String, dynamic> row) async {
    if (failReceiptRow) throw const BackendException(500, "row failed");
    receipts.add(row);
    return "rcpt-${receipts.length}";
  }

  @override
  Future<void> markReceiptEmailSent(String id) async =>
      sentMarks.add("receipt:$id");

  @override
  Future<void> insertAdjustment(Map<String, dynamic> row) async {
    if (failAdjustmentRow)
      throw BackendException(adjustmentRowStatus, "row failed");
    adjustments.add(row);
  }

  @override
  Future<void> markAdjustmentEmailSent(String id) async =>
      sentMarks.add("adjustment:$id");

  @override
  Future<EmailOutcome> sendEmail({
    required String template,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  }) async {
    if (failEmail) throw const BackendException(500, "email failed");
    emails.add(SentEmail(template, idempotencyKey, data));
    if (suppressAll) return EmailOutcome.suppressed;
    return EmailOutcome.sent;
  }

  @override
  Future<void> upsertHistory(List<Map<String, dynamic>> rows) async =>
      historyUpserts.add(rows);

  @override
  Future<List<Map<String, dynamic>>> historyRows({
    required String from,
    required String to,
    List<String>? carrierNames,
    List<int>? carrierIds,
  }) async {
    historyQueries.add(<String, String>{
      "from": from,
      "to": to,
      "names": (carrierNames ?? <String>[]).join("|")
    });
    return historyToReturn;
  }

  @override
  Future<UnsubscribeCheck> checkUnsubscribe(String token) async => checkResult;
  @override
  Future<UnsubscribeResult> confirmUnsubscribe(String token) async =>
      confirmResult;
}
