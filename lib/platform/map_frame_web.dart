// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import "dart:html" as html;
import "dart:ui_web" as ui_web;

import "package:flutter/material.dart";

final Set<String> _registered = <String>{};
final Map<String, html.IFrameElement> _frames = <String, html.IFrameElement>{};

String _viewType(String url) => "quai-map-${url.hashCode}";

/// Google Maps iframe. It starts NON-interactive (pointer-events: none) so a finger on the map still scrolls the page;
/// one tap on the "Touchez pour interagir" overlay unlocks it, the lock chip locks it again.
Widget buildMapFrame(String url, double height,
        {required String tapHint, required String lockLabel}) =>
    _MapFrame(url: url, height: height, tapHint: tapHint, lockLabel: lockLabel);

class _MapFrame extends StatefulWidget {
  const _MapFrame(
      {required this.url,
      required this.height,
      required this.tapHint,
      required this.lockLabel});
  final String url;
  final double height;
  final String tapHint;
  final String lockLabel;

  @override
  State<_MapFrame> createState() => _MapFrameState();
}

class _MapFrameState extends State<_MapFrame> {
  bool _active = false;

  @override
  void initState() {
    super.initState();
    final type = _viewType(widget.url);
    if (_registered.add(type)) {
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final f = html.IFrameElement()
          ..src = widget.url
          ..style.border = "0"
          ..style.width = "100%"
          ..style.height = "100%"
          ..style.pointerEvents = "none"
          ..allowFullscreen = true
          ..setAttribute("loading", "lazy")
          ..setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
        _frames[type] = f;
        return f;
      });
    }
  }

  void _set(bool on) {
    setState(() => _active = on);
    _frames[_viewType(widget.url)]?.style.pointerEvents = on ? "auto" : "none";
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key("map-frame"),
      height: widget.height,
      child: Stack(fit: StackFit.expand, children: <Widget>[
        HtmlElementView(viewType: _viewType(widget.url)),
        if (!_active)
          Positioned.fill(
            child: GestureDetector(
              key: const Key("map-tap-overlay"),
              behavior: HitTestBehavior.opaque,
              onTap: () => _set(true),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: const Color(0xCC1A1A1A),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(widget.tapHint,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          )
        else
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              key: const Key("map-lock"),
              onTap: () => _set(false),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: const Color(0xCC1A1A1A),
                    borderRadius: BorderRadius.circular(999)),
                child: Text(widget.lockLabel,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
      ]),
    );
  }
}
