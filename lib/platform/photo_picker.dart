import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

class PickedPhoto {
  const PickedPhoto(this.bytes, this.name);
  final Uint8List bytes;
  final String name;
}

/// Camera / gallery access. The real one (image_picker) lives in
/// lib/platform/image_picker_impl.dart, imported only by main.dart, so no test
/// and no other file touches the plugin.
abstract class PhotoPicker {
  /// Opens the camera (or the file chooser where there is no camera).
  Future<PickedPhoto?> takePhoto();

  /// Several images from the gallery / file chooser.
  Future<List<PickedPhoto>> pickMany();
}

class UnavailablePhotoPicker implements PhotoPicker {
  const UnavailablePhotoPicker();
  @override
  Future<PickedPhoto?> takePhoto() async => null;
  @override
  Future<List<PickedPhoto>> pickMany() async => <PickedPhoto>[];
}

final photoPickerProvider =
    Provider<PhotoPicker>((ref) => const UnavailablePhotoPicker());
