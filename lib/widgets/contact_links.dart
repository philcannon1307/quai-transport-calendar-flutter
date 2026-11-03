import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../i18n/i18n.dart";
import "../logic/contact_parser.dart";
import "../state/providers.dart";

/// Call + Directions buttons for an order, built from the ship-to phone and
/// address parsed out of its picking-ticket PDF. Renders nothing when the
/// contact is unknown, so a card never shows a dead button.
class ContactLinks extends ConsumerWidget {
  const ContactLinks({super.key, required this.soNum});
  final String soNum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(orderContactProvider(soNum));
    return contact.when(
      loading: () => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => const SizedBox.shrink(),
      data: (c) {
        if (c == null || c.isEmpty) return const SizedBox.shrink();
        final s = StringsScope.of(context);
        final launch = ref.read(urlLauncherProvider);
        final phone = c.phone;
        final address = c.address;
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
