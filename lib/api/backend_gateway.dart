import "dart:typed_data";

import "../logic/announcements.dart";

/// A call to the backend (database, storage or email function) failed.
class BackendException implements Exception {
  const BackendException(this.status, this.message);

  /// HTTP status, or 0 when the request never got an answer (offline, CORS...).
  final int status;
  final String message;

  @override
  String toString() => "BackendException($status): $message";
}

/// No backend URL/key was supplied at build time, so there is nothing to call.
class BackendNotConfigured extends BackendException {
  const BackendNotConfigured() : super(0, "Backend not configured");
}

enum EmailOutcome {
  /// Handed to the mail queue.
  sent,

  /// The recipient unsubscribed earlier: nothing was sent and that is by design.
  suppressed,
}

enum UnsubscribeCheck { valid, alreadyUnsubscribed, invalid }

enum UnsubscribeResult { done, alreadyUnsubscribed, error }

/// Everything the app needs from Supabase (REST + Storage + Edge Functions).
/// The real one speaks plain HTTP; tests use a fake.
abstract class BackendGateway {
  /// False when no backend was configured: callers must say so instead of
  /// pretending an empty list means "no data".
  bool get configured;

  // --- announcements
  Future<List<Announcement>> activeAnnouncements();
  Future<String> insertAnnouncement(Map<String, String> row);
  Future<void> updateAnnouncement(String id, Map<String, String> row);
  Future<void> deleteAnnouncement(String id);
  Future<void> insertAnnouncementImage(String announcementId, String url);
  Future<void> deleteAnnouncementImageByUrl(String url);

  // --- storage
  String publicUrl(String bucket, String path);
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  });
  Future<void> removeFiles(String bucket, List<String> paths);

  // --- receipts and change reports
  Future<String?> insertReceipt(Map<String, dynamic> row);
  Future<void> markReceiptEmailSent(String id);
  Future<void> insertAdjustment(Map<String, dynamic> row);
  Future<void> markAdjustmentEmailSent(String id);

  /// There is NO recipient parameter on purpose: the server computes recipients
  /// from the verified sender and the report/receipt id (see server-contract.md).
  Future<EmailOutcome> sendEmail({
    required String template,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  });

  // --- delivery history
  Future<void> upsertHistory(List<Map<String, dynamic>> rows);
  Future<List<Map<String, dynamic>>> historyRows({
    required String from,
    required String to,
    List<String>? carrierNames,
    List<int>? carrierIds,
  });

  // --- unsubscribe
  Future<UnsubscribeCheck> checkUnsubscribe(String token);
  Future<UnsubscribeResult> confirmUnsubscribe(String token);
}

/// Used when no backend was configured at build time.
class UnconfiguredBackend implements BackendGateway {
  const UnconfiguredBackend();

  @override
  bool get configured => false;

  Never _no() => throw const BackendNotConfigured();

  @override
  Future<List<Announcement>> activeAnnouncements() async => <Announcement>[];
  @override
  Future<String> insertAnnouncement(Map<String, String> row) async => _no();
  @override
  Future<void> updateAnnouncement(String id, Map<String, String> row) async =>
      _no();
  @override
  Future<void> deleteAnnouncement(String id) async => _no();
  @override
  Future<void> insertAnnouncementImage(
          String announcementId, String url) async =>
      _no();
  @override
  Future<void> deleteAnnouncementImageByUrl(String url) async => _no();
  @override
  String publicUrl(String bucket, String path) => "";
  @override
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async =>
      _no();
  @override
  Future<void> removeFiles(String bucket, List<String> paths) async => _no();
  @override
  Future<String?> insertReceipt(Map<String, dynamic> row) async => _no();
  @override
  Future<void> markReceiptEmailSent(String id) async => _no();
  @override
  Future<void> insertAdjustment(Map<String, dynamic> row) async => _no();
  @override
  Future<void> markAdjustmentEmailSent(String id) async => _no();
  @override
  Future<EmailOutcome> sendEmail({
    required String template,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  }) async =>
      _no();
  @override
  Future<void> upsertHistory(List<Map<String, dynamic>> rows) async {}
  @override
  Future<List<Map<String, dynamic>>> historyRows({
    required String from,
    required String to,
    List<String>? carrierNames,
    List<int>? carrierIds,
  }) async =>
      <Map<String, dynamic>>[];
  @override
  Future<UnsubscribeCheck> checkUnsubscribe(String token) async => _no();
  @override
  Future<UnsubscribeResult> confirmUnsubscribe(String token) async => _no();
}
