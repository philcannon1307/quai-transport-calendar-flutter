import "../models/carrier.dart";

// Carrier roster — ported VERBATIM from the React reference (src/lib/carriers.ts),
// MINUS every password field. Credentials live server-side (see api/auth_service.dart).
//
// `truck` = NetSuite `#TRUCK` custom list (customlist28) internal ID.
// Verified 1:1 against NetSuite on 2026-05-05. Do NOT modify without
// re-verifying in NetSuite (Lists -> Custom Lists -> # TRUCK with
// "Show Internal IDs" enabled).
//
// Important: `#TRUCK` is set on Calendar Events, NOT on Sales Orders.
// The backend must join Event -> SO via `event.transaction`. If orders
// aren't showing for a carrier, the bug is backend-side, not here.
//
// Solution Lac accounts are retired and excluded from this roster.

/// SADM dispatcher login with three calendars and a BOL upload button.
const String kLogistique = "SADM - Logistique";

const List<Carrier> kCarriers = <Carrier>[
  Carrier(displayName: "SADM - David", group: "SADM", truck: "62"),
  Carrier(displayName: "SADM - Éric", group: "SADM", truck: "43"),
  Carrier(displayName: "SADM - Jayson", group: "SADM", truck: "45"),
  Carrier(displayName: "SADM - Mathieu", group: "SADM", truck: "54"),
  Carrier(displayName: "SADM - Quai2go", group: "SADM", truck: "63"),
  Carrier(displayName: "SADM - Steve", group: "SADM", truck: "44"),
  Carrier(displayName: "Gat - Sam", group: "Gatineau", truck: "64"),
  Carrier(displayName: "Lindsay - Brendan", group: "Lindsay", truck: "66"),
  Carrier(displayName: "Lindsay - Cole", group: "Lindsay", truck: "67"),
  Carrier(displayName: "Lindsay - Laurent", group: "Lindsay", truck: "68"),
  Carrier(displayName: "Mt-Laurier - Steve", group: "Mt-Laurier", truck: "69"),
  Carrier(displayName: "Québec - Justin", group: "Québec", truck: "70"),
  Carrier(displayName: "Québec - Marc", group: "Québec", truck: "71"),
  Carrier(displayName: "Sherbrooke - Hervé", group: "Sherbrooke", truck: "72"),
  Carrier(
    displayName: "InterQL",
    group: "Gooseneck",
    truck: "3",
    backendUsername: "RIDEAU GOOSENECK",
    linkedTrucks: <LinkedTruck>[
      LinkedTruck(displayName: "OPEN GOOSENECK", truck: "4")
    ],
  ),
  Carrier(displayName: "DA TRANSPORT", group: "Externe", truck: "58"),
  Carrier(displayName: "LANCEZ TRANSPORT", group: "Externe", truck: "59"),
  Carrier(displayName: "SD PRESTIGE", group: "Externe", truck: "73"),
  // SADM dispatcher: app-only login that reads every SADM truck + both Gooseneck trucks (TOs).
  // Kept last so per-truck calendar names keep resolving to the individual trucks.
  Carrier(
    displayName: kLogistique,
    group: "SADM",
    truck: "62",
    backendUsername: "SADM - David",
    linkedTrucks: <LinkedTruck>[
      LinkedTruck(displayName: "SADM - Éric", truck: "43"),
      LinkedTruck(displayName: "SADM - Jayson", truck: "45"),
      LinkedTruck(displayName: "SADM - Mathieu", truck: "54"),
      LinkedTruck(displayName: "SADM - Quai2go", truck: "63"),
      LinkedTruck(displayName: "SADM - Steve", truck: "44"),
      LinkedTruck(displayName: "RIDEAU GOOSENECK", truck: "3"),
      LinkedTruck(displayName: "OPEN GOOSENECK", truck: "4"),
    ],
  ),
];

/// One backend account per truck, labelled with its shared calendar name.
List<CarrierAccount> carrierAccounts(List<Carrier> carriers) {
  final seen = <String>{};
  final out = <CarrierAccount>[];
  for (final c in carriers) {
    final rows = <CarrierAccount>[
      CarrierAccount(
          displayName: c.displayName,
          username: c.backendUsername ?? c.displayName,
          truck: c.truck),
      ...c.linkedTrucks.map((t) => CarrierAccount(
          displayName: c.displayName, username: t.displayName, truck: t.truck)),
    ];
    for (final r in rows) {
      if (seen.add(r.username)) out.add(r);
    }
  }
  return out;
}

String calendarName(String name) {
  for (final c in kCarriers) {
    if (c.displayName == name ||
        c.backendUsername == name ||
        c.linkedTrucks.any((t) => t.displayName == name)) {
      return c.displayName;
    }
  }
  return name;
}

/// Branch inbox that receives on-site change reports, per carrier group.
const Map<String, String> kGroupInbox = <String, String>{
  "SADM": "sadm@groupeql.com",
  "Gooseneck": "sadm@groupeql.com",
  "Gatineau": "gatineau@groupeql.com",
  "Lindsay": "lindsay@groupeql.com",
  "Mt-Laurier": "mt-laurier@groupeql.com",
  "Québec": "quebec@groupeql.com",
  "Externe": "quebec@groupeql.com",
  "Sherbrooke": "estrie@groupeql.com",
};
const String kFallbackInbox = "comptabilite@groupeql.com";

String adjustmentInbox(String name) {
  final display = calendarName(name);
  for (final c in kCarriers) {
    if (c.displayName == display) return kGroupInbox[c.group] ?? kFallbackInbox;
  }
  return kFallbackInbox;
}

const Map<String, String> _accentFolds = <String, String>{
  "à": "a",
  "â": "a",
  "ä": "a",
  "é": "e",
  "è": "e",
  "ê": "e",
  "ë": "e",
  "î": "i",
  "ï": "i",
  "ô": "o",
  "ö": "o",
  "ù": "u",
  "û": "u",
  "ü": "u",
  "ç": "c",
};

String _fold(String s) {
  var out = s.toLowerCase();
  _accentFolds.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

/// Store inbox for a NetSuite location name (e.g. "Ste-Agathe", "Lindsay").
String? locationInbox(String location) {
  final n = _fold(location);
  if (RegExp(r"agathe|sadm").hasMatch(n)) return kGroupInbox["SADM"];
  if (n.contains("gatineau")) return kGroupInbox["Gatineau"];
  if (n.contains("lindsay")) return kGroupInbox["Lindsay"];
  if (n.contains("laurier")) return kGroupInbox["Mt-Laurier"];
  if (n.contains("quebec")) return kGroupInbox["Québec"];
  if (RegExp(r"sherbrooke|estrie").hasMatch(n))
    return kGroupInbox["Sherbrooke"];
  return null;
}

/// Recipients for a change report: transfers go to both stores involved;
/// otherwise the carrier's group inbox.
List<String> adjustmentRecipients(String carrier,
    [List<String> transferLocations = const <String>[]]) {
  final stores =
      transferLocations.map(locationInbox).whereType<String>().toList();
  final list = stores.isNotEmpty ? stores : <String>[adjustmentInbox(carrier)];
  final seen = <String>{};
  return list.where(seen.add).toList();
}

/// Linked trucks to sign in to and load. SADM - Logistique only needs the
/// Gooseneck trucks (for transfers); its SADM jobs come from the calendar source.
List<LinkedTruck> loadableLinkedTrucks(Carrier? carrier) {
  final linked = carrier?.linkedTrucks ?? const <LinkedTruck>[];
  if (carrier?.displayName == kLogistique) {
    return linked
        .where((t) =>
            RegExp("GOOSENECK", caseSensitive: false).hasMatch(t.displayName))
        .toList();
  }
  return linked.toList();
}

/// Only events whose title starts with an SADM truck ("SADM - …") belong to SADM.
bool isSadmEventTitle(String title) =>
    RegExp(r"^\s*SADM\s*-", caseSensitive: false).hasMatch(title);

Carrier? carrierByDisplayName(String name) {
  for (final c in kCarriers) {
    if (c.displayName == name) return c;
  }
  return null;
}

/// Carriers grouped for the login dropdown, in roster order.
Map<String, List<Carrier>> carriersByGroup() {
  final out = <String, List<Carrier>>{};
  for (final c in kCarriers) {
    out.putIfAbsent(c.group, () => <Carrier>[]).add(c);
  }
  return out;
}
