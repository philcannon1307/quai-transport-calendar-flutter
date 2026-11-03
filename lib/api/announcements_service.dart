import "dart:typed_data";

import "../logic/announcements.dart";
import "../logic/image_compress.dart";
import "backend_gateway.dart";

enum AnnouncementFailure { invalid, notConfigured, save, photo }

class AnnouncementResult {
  const AnnouncementResult.ok({this.photosFailed = 0}) : failure = null;
  const AnnouncementResult.failed(AnnouncementFailure this.failure) : photosFailed = 0;

  final AnnouncementFailure? failure;

  /// The announcement itself was saved but this many photos could not be.
  final int photosFailed;

  bool get isOk => failure == null;
}

class NewPhoto {
  const NewPhoto(this.bytes, this.name);
  final Uint8List bytes;
  final String name;
}

/// Announcement banner: everyone reads, only the SuperUser edits.
///
/// NOTE: "only the SuperUser edits" is enforced by the UI alone. The reference
/// database lets anyone with the public key write these tables, so this is
/// not a security boundary until the row-level-security policies are tightened.
class AnnouncementsService {
  AnnouncementsService({required this.gateway, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final BackendGateway gateway;
  final DateTime Function() _clock;

  Future<List<Announcement>> list() async {
    try {
      return await gateway.activeAnnouncements();
    } on BackendException {
      return <Announcement>[]; // silent, as in the reference
    }
  }

  /// Create ([existing] == null) or update an announcement, remove the photos
  /// the editor dropped, and upload the new ones.
  Future<AnnouncementResult> save({
    required AnnouncementDraft draft,
    Announcement? existing,
    List<NewPhoto> newPhotos = const <NewPhoto>[],
    List<String> removedUrls = const <String>[],
  }) async {
    if (!draft.isValid) return const AnnouncementResult.failed(AnnouncementFailure.invalid);
    if (!gateway.configured) return const AnnouncementResult.failed(AnnouncementFailure.notConfigured);

    final String id;
    try {
      if (existing != null) {
        await gateway.updateAnnouncement(existing.id, draft.toRow());
        id = existing.id;
      } else {
        id = await gateway.insertAnnouncement(draft.toRow());
      }
    } on BackendException {
      return const AnnouncementResult.failed(AnnouncementFailure.save);
    }

    // Dropped photos: delete the file, then the row. Failures are tolerated; a
    // leftover file is harmless, a leftover row would show a broken image, so
    // the row is removed even if the file removal failed.
    if (removedUrls.isNotEmpty) {
      final paths = removedUrls.map((u) => storagePathFromUrl(u, kAnnouncementBucket)).whereType<String>().toList();
      try {
        await gateway.removeFiles(kAnnouncementBucket, paths);
      } on BackendException {
        // ignored
      }
      for (final url in removedUrls) {
        try {
          await gateway.deleteAnnouncementImageByUrl(url);
        } on BackendException {
          // ignored
        }
      }
    }

    var failed = 0;
    final stampMs = _clock().millisecondsSinceEpoch;
    for (final photo in newPhotos) {
      try {
        final image = compressForUpload(photo.bytes);
        final path = "$id/$stampMs-${uploadFileName(photo.name)}";
        final url = await gateway.uploadFile(
          bucket: kAnnouncementBucket,
          path: path,
          bytes: image.bytes,
          contentType: image.mimeType,
        );
        await gateway.insertAnnouncementImage(id, url);
      } on ImageCompressException {
        failed++;
      } on BackendException {
        failed++;
      }
    }
    return AnnouncementResult.ok(photosFailed: failed);
  }

  /// Delete the announcement and its photos (files first, then the row, which
  /// cascades to the photo rows).
  Future<bool> delete(Announcement a) async {
    if (!gateway.configured) return false;
    try {
      final paths = a.images.map((u) => storagePathFromUrl(u, kAnnouncementBucket)).whereType<String>().toList();
      if (paths.isNotEmpty) {
        try {
          await gateway.removeFiles(kAnnouncementBucket, paths);
        } on BackendException {
          // a leftover file must not block deleting the announcement
        }
      }
      await gateway.deleteAnnouncement(a.id);
      return true;
    } on BackendException {
      return false;
    }
  }
}
