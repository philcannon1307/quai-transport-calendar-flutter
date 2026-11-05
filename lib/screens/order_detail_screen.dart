import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/sales_order_service.dart";
import "../i18n/i18n.dart";
import "../logic/calendar_week.dart";
import "../logic/contact_parser.dart";
import "../logic/map_embed.dart";
import "../models/order.dart";
import "../platform/map_frame.dart";
import "../state/prep_providers.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "../widgets/bilingual.dart";
import "../widgets/calendar_common.dart";
import "../widgets/order_card.dart";
import "../widgets/prep_widgets.dart";
import "../widgets/status_chip.dart";
import "ticket_sheet.dart";

/// Opens the order detail (logistics + SuperUser): client, call / maps, key facts, driver memo, items, the picking
/// ticket ("Bon de vente") and the sticky "prepared" button. Money (deposit / balance) is deliberately never shown here.
Future<void> showOrderDetail(BuildContext context, Order order) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(order: order)),
  );
}

class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.order});
  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final s = StringsScope.of(context);
    final status = statusOf(order);
    final contact = order.isTransfer
        ? null
        : ref.watch(orderContactProvider(order.soNum)).valueOrNull;
    final details = (order.isTransfer || (order.soId ?? 0) <= 0)
        ? null
        : ref.watch(salesOrderDetailsProvider(order.soId!)).valueOrNull;
    final phone = _first(contact?.phone, details?.phone);
    final address = _first(
        contact?.address, _join(<String?>[details?.address, details?.city]));
    final launch = ref.read(urlLauncherProvider);
    final date = OrderDate.of(order);
    final memo = (order.memo ?? "").trim().isNotEmpty
        ? order.memo!.trim()
        : (details?.memo ?? "").trim();
    final List<SalesOrderItem> items =
        details?.items ?? const <SalesOrderItem>[];
    final showPrep = PrepButton.visibleFor(ref, order);

    Widget tile(String keyName, String label, String? value) => Container(
          key: Key("detail-tile-$keyName"),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(QuaiRadius.sm),
              border: Border.all(color: c.line)),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label.toUpperCase(),
                    style: quaiSans(c.sub,
                        size: 10.5,
                        height: 12,
                        weight: FontWeight.w700,
                        ls: .6)),
                const SizedBox(height: 4),
                Text((value ?? "").trim().isEmpty ? "—" : value!.trim(),
                    style: quaiSans(c.ink,
                        size: 14, height: 19, weight: FontWeight.w700)),
              ]),
        );

    final tiles = <Widget>[
      tile("date", bi(s, "Date", "Date"),
          date == null ? order.date : CalFmt(s).dayLong(date)),
      tile("method", bi(s, "Méthode", "Method"), order.serviceType),
      tile("truck", bi(s, "Camion", "Truck"), order.truckName),
      tile("unit", bi(s, "Unité", "Unit"),
          _first(order.carrierName, order.shippingLocationName)),
    ];

    return Scaffold(
      key: const Key("order-detail"),
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        foregroundColor: c.ink,
        elevation: 0,
        title: Text(order.soNum,
            key: const Key("detail-title"), style: quaiMono(c.ink, size: 15)),
        actions: <Widget>[
          if (status != null)
            Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(child: StatusChip(status: status)))
        ],
      ),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            Text((order.customer ?? "").isEmpty ? order.soNum : order.customer!,
                key: const Key("detail-customer"),
                style: quaiSans(c.ink,
                    size: 22, height: 28, weight: FontWeight.w700)),
            if (phone != null) ...<Widget>[
              const SizedBox(height: 6),
              SelectableText(phone,
                  key: const Key("detail-phone"),
                  style: quaiSans(c.sub, size: 15, height: 20)),
            ],
            if (address != null) ...<Widget>[
              const SizedBox(height: 4),
              SelectableText(address,
                  key: const Key("detail-address"),
                  style: quaiSans(c.sub, size: 15, height: 20)),
            ],
            const SizedBox(height: 14),
            Row(children: <Widget>[
              Expanded(
                child: _BigAction(
                  buttonKey: const Key("detail-call"),
                  icon: Icons.phone,
                  label: bi(s, "Appeler", "Call"),
                  onTap: phone == null
                      ? null
                      : () => launch(Uri.parse(telHref(phone))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigAction(
                  buttonKey: const Key("detail-maps"),
                  icon: Icons.navigation,
                  label: bi(s, "Ouvrir dans Maps", "Open in Maps"),
                  onTap: address == null
                      ? null
                      : () => launch(Uri.parse(mapsHref(address))),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _MapCard(
                address: address,
                wide: MediaQuery.sizeOf(context).width >= 700),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, box) {
              final w = (box.maxWidth - 12) / 2;
              return Wrap(spacing: 12, runSpacing: 12, children: <Widget>[
                for (final t in tiles) SizedBox(width: w, child: t)
              ]);
            }),
            if (memo.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                key: const Key("detail-memo"),
                width: double.infinity,
                decoration: BoxDecoration(
                    color: c.memoBg,
                    borderRadius: BorderRadius.circular(QuaiRadius.sm)),
                child: IntrinsicHeight(
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Container(
                            width: 5,
                            decoration: BoxDecoration(
                                color: c.memoRail,
                                borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(QuaiRadius.sm)))),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                      bi(s, "MÉMO DU CHAUFFEUR", "DRIVER MEMO"),
                                      style: quaiSans(c.primaryInk,
                                          size: 11,
                                          height: 14,
                                          weight: FontWeight.w700,
                                          ls: .6)),
                                  const SizedBox(height: 4),
                                  // Never truncated: the driver must read all of it.
                                  Text(memo,
                                      key: const Key("detail-memo-text"),
                                      style: quaiSans(c.ink,
                                          size: 16,
                                          height: 22,
                                          weight: FontWeight.w600)),
                                ]),
                          ),
                        ),
                      ]),
                ),
              ),
            ],
            if (items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text(bi(s, "Articles", "Items"),
                  style: quaiSans(c.ink,
                      size: 15, height: 20, weight: FontWeight.w700)),
              const SizedBox(height: 6),
              Container(
                key: const Key("detail-items"),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(QuaiRadius.sm),
                    border: Border.all(color: c.line)),
                child: Column(children: <Widget>[
                  for (final it in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SizedBox(
                                width: 64,
                                child: Text(
                                    it.quantity == null
                                        ? ""
                                        : "${it.quantity} ${it.unit}".trim(),
                                    style: quaiMono(c.ink, size: 13))),
                            Expanded(
                                child: Text(
                                    [
                                      it.name,
                                      if (it.memo.isNotEmpty) "— ${it.memo}"
                                    ].join(" "),
                                    style:
                                        quaiSans(c.ink, size: 14, height: 20))),
                          ]),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                key: const Key("detail-ticket"),
                onPressed: () =>
                    showTicketSheet(context, order.soNum, order: order),
                icon: const Icon(Icons.description_outlined),
                label: Text(bi(s, "Bon de vente", "Sales slip"),
                    style: quaiSans(c.ink, size: 15, weight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                    foregroundColor: c.ink,
                    side: BorderSide(color: c.ink, width: 1.5),
                    shape: const StadiumBorder()),
              ),
            ),
          ]),
      bottomNavigationBar: showPrep
          ? SafeArea(
              child: Container(
                key: const Key("detail-prep-bar"),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: BoxDecoration(
                    color: c.surface,
                    border: Border(top: BorderSide(color: c.line))),
                child: PrepButton(order: order),
              ),
            )
          : null,
    );
  }
}

String? _first(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a.trim();
  if (b != null && b.trim().isNotEmpty) return b.trim();
  return null;
}

String? _join(List<String?> parts) {
  final p = parts
      .where((e) => e != null && e.trim().isNotEmpty)
      .map((e) => e!.trim())
      .toList();
  return p.isEmpty ? null : p.join(", ");
}

/// 56 px orange action (dark text on orange keeps the contrast of the Ember palette).
class _BigAction extends StatelessWidget {
  const _BigAction(
      {required this.buttonKey,
      required this.icon,
      required this.label,
      required this.onTap});
  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        key: buttonKey,
        onPressed: onTap,
        icon: Icon(icon, size: 22),
        label: Text(label,
            style: quaiSans(c.onPrimary, size: 16, weight: FontWeight.w700)),
        style: FilledButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: c.onPrimary,
          disabledBackgroundColor: c.field,
          disabledForegroundColor: c.faint,
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

/// Embedded map under the Call / Open-in-Maps row. Hidden (with a short message) when the address is missing or unusable.
class _MapCard extends StatelessWidget {
  const _MapCard({required this.address, required this.wide});
  final String? address;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    final query = mapQueryFor(address);
    if (query == null) {
      return Container(
        key: const Key("detail-map-missing"),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(QuaiRadius.sm),
            border: Border.all(color: c.line)),
        child: Text(
            bi(s, "Adresse manquante ou incomplète : carte non affichée.",
                "Address missing or incomplete: map not shown."),
            style: quaiSans(c.sub, size: 14, height: 19)),
      );
    }
    return Container(
      key: const Key("detail-map"),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: c.field,
          borderRadius: BorderRadius.circular(QuaiRadius.lg),
          border: Border.all(color: c.line)),
      child: buildMapFrame(mapEmbedUrl(query), wide ? 360 : 220,
          tapHint: bi(s, "Touchez pour interagir", "Tap to interact"),
          lockLabel: bi(s, "Verrouiller", "Lock")),
    );
  }
}
