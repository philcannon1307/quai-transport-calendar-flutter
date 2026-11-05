import "package:flutter/material.dart";

import "../api/sales_order_service.dart";
import "../theme/quai_tokens.dart";

/// "Bon de commande" built from the sales order alone, for orders with no truck yet.
/// Labelled provisional; the item list fills in when the middleware starts serving items.
class ProvisionalTicketView extends StatelessWidget {
  const ProvisionalTicketView({super.key, required this.details});

  final SalesOrderDetails details;

  Widget _row(QuaiColors c, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 150, child: Text(label, style: quaiSans(c.sub, size: 13, height: 18, weight: FontWeight.w700))),
          Expanded(child: SelectableText(value, style: quaiSans(c.ink, size: 14, height: 20))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final d = details;
    final items = d.items;
    return ColoredBox(
      color: c.bg,
      child: ListView(
        key: const Key("provisional-ticket"),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Container(
            key: const Key("provisional-banner"),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.tentativeBg, border: Border.all(color: c.tentative.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(QuaiRadius.sm)),
            child: Text(
              "PROVISOIRE — aucun camion assigné / PROVISIONAL — no truck assigned yet",
              style: quaiSans(c.tentative, size: 13, height: 18, weight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          Text("Bon de commande / Picking list  ${d.soNum}", style: quaiSans(c.ink, size: 18, height: 24, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          _row(c, "Client / Customer", d.customer),
          _row(c, "Adresse / Address", d.address),
          _row(c, "Ville / City", d.city),
          _row(c, "Téléphone / Phone", d.phone),
          _row(c, "Service", d.service),
          _row(c, "Événement / Event", d.eventName),
          _row(c, "Statut / Status", d.status),
          _row(c, "Emplacement / Location", d.location),
          _row(c, "Méthode / Method", d.shippingMethod),
          _row(c, "Date de commande / Order date", d.orderDate),
          _row(c, "Date d'expédition / Ship date", d.shipDate),
          _row(c, "Date promise / Promise date", d.promiseDate),
          _row(c, "Mémo / Memo", d.memo),
          Divider(height: 24, color: c.line),
          Text("Articles / Items", style: quaiSans(c.ink, size: 14, height: 20, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (items == null)
            Text(
              "Items not available yet — Articles non disponibles pour le moment",
              key: const Key("provisional-items-missing"),
              style: quaiSans(c.sub, size: 13, height: 18).copyWith(fontStyle: FontStyle.italic),
            )
          else if (items.isEmpty)
            Text("Aucun article / No items", key: const Key("provisional-items-empty"), style: quaiSans(c.sub, size: 13, height: 18))
          else
            Column(
              key: const Key("provisional-items"),
              children: <Widget>[
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(width: 56, child: Text(it.quantity == null ? "" : "${it.quantity} ${it.unit}".trim(), style: quaiMono(c.ink, size: 13))),
                        Expanded(child: Text([it.name, if (it.sku.isNotEmpty) "(${it.sku})", if (it.memo.isNotEmpty) "— ${it.memo}"].join(" "), style: quaiSans(c.ink, size: 14, height: 20))),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
