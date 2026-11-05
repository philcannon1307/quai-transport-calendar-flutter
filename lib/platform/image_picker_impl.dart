import "package:image_picker/image_picker.dart";

import "photo_picker.dart";

/// The ONLY file that imports image_picker.
class ImagePickerPhotoPicker implements PhotoPicker {
  ImagePickerPhotoPicker({ImagePicker? picker})
      : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  @override
  Future<PickedPhoto?> takePhoto() async {
    final file = await _picker.pickImage(source: ImageSource.camera);
    if (file == null) return null;
    return PickedPhoto(await file.readAsBytes(), file.name);
  }

  @override
  Future<List<PickedPhoto>> pickMany() async {
    final files = await _picker.pickMultiImage();
    final out = <PickedPhoto>[];
    for (final f in files) {
      out.add(PickedPhoto(await f.readAsBytes(), f.name));
    }
    return out;
  }
}
