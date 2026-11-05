import "package:flutter/material.dart";

/// Non-web stand-in (and what `flutter test` sees). The web build swaps in map_frame_web.dart.
Widget buildMapFrame(String url, double height,
        {required String tapHint, required String lockLabel, bool interactive = true}) =>
    SizedBox(
        key: const Key("map-frame"),
        height: height,
        child: Center(child: Text(url, key: const Key("map-frame-url"))));
