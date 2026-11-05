import "package:flutter/material.dart";

import "../api/sales_order_service.dart";

/// "Bon de commande" built from the sales order alone, for orders with no truck yet.
/// Labelled provisional; the item list fills in when the middleware starts serving items.
class ProvisionalTicketView extends StatelessWidget {
  const ProvisionalTicketView({super.key, required this.details});

  final SalesOrderDetails details;

  Widget _row(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 150, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black54))),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = details;
    final items = d.items;
    return ColoredBox(
      color: Colors.white,
      child: ListView(
        key: const Key("provisional-ticket"),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Container(
            key: const Key("provisional-banner"),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFFF3CD), border: Border.all(color: const Color(0xFFE0A800)), borderRadius: BorderRadius.circular(8)),
            child: const Text(
              "PROVISOIRE — aucun camion assigné / PROVISIONAL — no truck assigned yet",
              style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF664D03)),
            ),
          ),
          const SizedBox(height: 12),
          Text("Bon de commande / Picking list  ${d.soNum}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _row("Client / Customer", d.customer),
          _row("Adresse / Address", d.address),
          _row("Ville / City", d.city),
          _row("Téléphone / Phone", d.phone),
          _row("Service", d.service),
          _row("Événement / Event", d.eventName),
          _row("Statut / Status", d.status),
          _row("Emplacement / Location", d.location),
          _row("Méthode / Method", d.shippingMethod),
          _row("Date de commande / Order date", d.orderDate),
          _row("Date d'expédition / Ship date", d.shipDate),
          _row("Date promise / Promise date", d.promiseDate),
          _row("Mémo / Memo", d.memo),
          const Divider(height: 24),
          const Text("Articles / Items", style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (items == null)
            const Text(
              "Items not available yet — Articles non disponibles pour le moment",
              key: Key("provisional-items-missing"),
              style: TextStyle(fontStyle: FontStyle.italic, color: Colors.black54),
            )
          else if (items.isEmpty)
            const Text("Aucun article / No items", key: Key("provisional-items-empty"))
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
                        SizedBox(width: 56, child: Text(it.quantity == null ? "" : "${it.quantity} ${it.unit}".trim(), style: const TextStyle(fontWeight: FontWeight.w700))),
                        Expanded(child: Text([it.name, if (it.sku.isNotEmpty) "(${it.sku})", if (it.memo.isNotEmpty) "— ${it.memo}"].join(" "))),
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
