import "dart:typed_data";

import "package:image/image.dart" as img;

/// Phone photos are 3-8 MB; receipts only need to be legible. Everything that
/// is uploaded is re-encoded to fit ~1600 px on its longest side and ~300 KB.
const int kMaxImageSide = 1600;
const int kMaxImageBytes = 300 * 1024;

class CompressedImage {
  const CompressedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.quality,
    required this.withinBudget,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// JPEG quality that was finally used (40..85).
  final int quality;

  /// False only for a pathological image that could not reach [kMaxImageBytes]
  /// even after shrinking; it is still returned so the upload can proceed.
  final bool withinBudget;

  String get mimeType => "image/jpeg";
  String get extension => "jpg";
}

/// The file is not an image the decoder understands (corrupt, or a PDF/other).
class ImageCompressException implements Exception {
  const ImageCompressException(this.message);
  final String message;
  @override
  String toString() => message;
}

img.Image _fit(img.Image image, int maxSide) {
  if (image.width <= maxSide && image.height <= maxSide) return image;
  return image.width >= image.height
      ? img.copyResize(image, width: maxSide)
      : img.copyResize(image, height: maxSide);
}

/// Decode -> fix EXIF rotation -> fit [maxSide] -> JPEG, lowering quality and
/// then size until the result is <= [maxBytes].
///
/// Synchronous and CPU-bound: on the web it runs on the UI thread, so callers
/// should show a "sending" state first.
CompressedImage compressForUpload(
  Uint8List input, {
  int maxSide = kMaxImageSide,
  int maxBytes = kMaxImageBytes,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(input);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) throw const ImageCompressException("Unreadable image");

  // Phones store portrait shots as landscape pixels + an EXIF flag; without
  // this the uploaded receipt would arrive sideways.
  var image = _fit(img.bakeOrientation(decoded), maxSide);

  var quality = 85;
  var out = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  while (out.length > maxBytes && quality > 40) {
    quality -= 15;
    if (quality < 40) quality = 40;
    out = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  // Still too big at the lowest quality: shrink by 15% steps.
  var shrinks = 0;
  while (out.length > maxBytes && shrinks < 8) {
    final w = (image.width * 0.85).round();
    if (w < 64) break;
    image = img.copyResize(image, width: w);
    out = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    shrinks++;
  }

  return CompressedImage(
    bytes: out,
    width: image.width,
    height: image.height,
    quality: quality,
    withinBudget: out.length <= maxBytes,
  );
}
