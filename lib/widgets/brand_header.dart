import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_svg/flutter_svg.dart";

import "../state/providers.dart";
import "../theme/quai_tokens.dart";

/// Official LAFANTAISIE wordmark (SVG master, viewBox 722.87 x 92.5). White on ink, black on light.
/// Minimum 96 px wide on screen. Never stretched, never on the orange.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.width = 150, this.white = true});
  final double width;
  final bool white;

  @override
  Widget build(BuildContext context) {
    final w = width < 96 ? 96.0 : width;
    return SvgPicture.asset(
      white
          ? "assets/lafantaisie-logo-white.svg"
          : "assets/lafantaisie-logo-black.svg",
      key: Key(white ? "brand-logo-white" : "brand-logo-black"),
      width: w,
      height: w * 92.5 / 722.87,
      semanticsLabel: "LAFANTAISIE",
    );
  }
}

/// Ink gradient with faint diagonal "dock-deck" stripes. Signature element:
/// sign-in hero and the app bar only.
class BrandHeader extends StatelessWidget {
  const BrandHeader(
      {super.key,
      required this.child,
      this.height,
      this.padding = EdgeInsets.zero,
      this.stripeAlpha = 0.06});
  final Widget child;
  final double? height;
  final EdgeInsetsGeometry padding;
  final double stripeAlpha;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return Container(
      key: const Key("brand-header"),
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[c.header, c.headerEnd]),
      ),
      child: CustomPaint(
        painter: DockStripesPainter(alpha: stripeAlpha),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// White "/" stripes, 1 px every 18 px.
class DockStripesPainter extends CustomPainter {
  const DockStripesPainter({this.alpha = 0.06, this.gap = 18});
  final double alpha;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(DockStripesPainter old) =>
      old.alpha != alpha || old.gap != gap;
}

/// FR / EN pill (84 x 30): selected segment white on #3A3A3A. Same control on every screen.
class LangToggle extends ConsumerWidget {
  const LangToggle({super.key});

  static const Color _track = Color(0xFF3A3A3A);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFr = ref.watch(localeProvider).languageCode != "en";
    Widget seg(String label, bool active, Locale locale) => Expanded(
          child: GestureDetector(
            key: Key("lang-${label.toLowerCase()}"),
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(localeProvider.notifier).state = locale,
            child: AnimatedContainer(
              duration: QuaiMotion.segment,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: active ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(QuaiRadius.full)),
              child: Text(label,
                  style: quaiSans(
                      active
                          ? const Color(0xFF1A1A1A)
                          : const Color(0xFFB5B1AB),
                      size: 12,
                      weight: FontWeight.w700)),
            ),
          ),
        );
    return Container(
      width: 84,
      height: 30,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
          color: _track, borderRadius: BorderRadius.circular(QuaiRadius.full)),
      child: Row(children: <Widget>[
        seg("FR", isFr, const Locale("fr")),
        seg("EN", !isFr, const Locale("en"))
      ]),
    );
  }
}
