// Platform switch: the real iframe on Flutter web, a plain keyed placeholder everywhere else (tests, mobile).
export "map_frame_stub.dart" if (dart.library.html) "map_frame_web.dart";
