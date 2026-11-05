import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../i18n/i18n.dart";
import "../logic/contact_parser.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";

/// Call + Directions buttons for an order, built from the ship-to phone and
/// address parsed out of its picking-ticket PDF. Renders nothing when the
/// contact is unknown, so a card never shows a dead button.
class ContactLinks extends ConsumerWidget {
  const ContactLinks(
      {super.key, required this.soNum, this.round = false, this.small = false});
  final String soNum;

  /// Round icon-only buttons (call / navigate) used on order cards.
  final bool round;
  final bool small;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(orderContactProvider(soNum));
    return contact.when(
      loading: () => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => const SizedBox.shrink(),
      data: (c) {
        if (c == null || c.isEmpty) return const SizedBox.shrink();
        final s = StringsScope.of(context);
        final launch = ref.read(urlLauncherProvider);
        final phone = c.phone;
        final address = c.address;
        if (round) {
          return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            if (phone != null)
              RoundIconButton(
                key: Key("call-$soNum"),
                tooltip: phone,
                icon: Icons.phone_outlined,
                small: small,
                onTap: () => launch(Uri.parse(telHref(phone))),
              ),
            if (phone != null && address != null)
              SizedBox(width: small ? 4 : 8),
            if (address != null)
              RoundIconButton(
                key: Key("maps-$soNum"),
                tooltip: s.isFrench ? "Itinéraire" : "Directions",
                icon: Icons.navigation_outlined,
                small: small,
                onTap: () => launch(Uri.parse(mapsHref(address))),
              ),
          ]);
        }
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            if (phone != null)
              OutlinedButton.icon(
                key: Key("call-$soNum"),
                onPressed: () => launch(Uri.parse(telHref(phone))),
                icon: const Icon(Icons.phone, size: 16),
                label: Text(phone),
              ),
            if (address != null)
              OutlinedButton.icon(
                key: Key("maps-$soNum"),
                onPressed: () => launch(Uri.parse(mapsHref(address))),
                icon: const Icon(Icons.navigation_outlined, size: 16),
                label: Text(s.isFrench ? "Itinéraire" : "Directions"),
              ),
          ],
        );
      },
    );
  }
}

/// 36 px circular outlined action (26 px when `small`), 44 px tap target through padding.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton(
      {super.key,
      required this.tooltip,
      required this.icon,
      required this.onTap,
      this.small = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final size = small ? 26.0 : 36.0;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Padding(
          padding: EdgeInsets.all(small ? 2 : 4),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surface,
                border: Border.all(color: c.line)),
            child: Icon(icon, size: small ? 14 : 18, color: c.ink),
          ),
        ),
      ),
    );
  }
}
