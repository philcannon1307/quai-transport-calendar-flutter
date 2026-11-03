import "dart:math";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:quai_calendar/logic/image_compress.dart";

/// Noisy picture: noise defeats JPEG, so it behaves like a real photo and
/// forces the quality/size loop to work.
Uint8List _noisy(int w, int h, {int seed = 1}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p.r = r.nextInt(256);
    p.g = r.nextInt(256);
    p.b = r.nextInt(256);
  }
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  test("a large photo is resized to <= 1600 px and <= 300 KB", () {
    final out = compressForUpload(_noisy(2400, 1800));
    expect(out.width, lessThanOrEqualTo(kMaxImageSide));
    expect(out.height, lessThanOrEqualTo(kMaxImageSide));
    expect(out.width / out.height, closeTo(2400 / 1800, 0.02), reason: "aspect ratio kept");
    expect(out.bytes.length, lessThanOrEqualTo(kMaxImageBytes));
    expect(out.withinBudget, isTrue);
    // really a JPEG
    expect(out.bytes[0], 0xFF);
    expect(out.bytes[1], 0xD8);
  });

  test("a portrait photo is limited on its height", () {
    final out = compressForUpload(_noisy(1200, 2400));
    expect(out.height, lessThanOrEqualTo(kMaxImageSide));
    expect(out.width, lessThan(out.height));
  });

  test("a small image is not enlarged", () {
    final out = compressForUpload(_noisy(200, 100));
    expect(out.width, 200);
    expect(out.height, 100);
  });

  test("garbage bytes raise ImageCompressException instead of uploading junk", () {
    expect(() => compressForUpload(Uint8List.fromList(<int>[1, 2, 3, 4])), throwsA(isA<ImageCompressException>()));
    expect(() => compressForUpload(Uint8List(0)), throwsA(isA<ImageCompressException>()));
  });

  test("an impossible budget still returns an image and says it is over budget", () {
    final out = compressForUpload(_noisy(800, 800), maxBytes: 200);
    expect(out.withinBudget, isFalse);
    expect(out.bytes, isNotEmpty);
  });
}
