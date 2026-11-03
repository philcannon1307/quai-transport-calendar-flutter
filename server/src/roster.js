// Carrier roster. MUST stay identical to lib/data/carriers.dart (the Flutter app);
// test/roster.test.js fails when they drift. Passwords are NOT here: they come from
// the CARRIER_CREDENTIALS_JSON environment variable.

export const SUPERUSER_NAME = "SuperUser";
export const LOGISTIQUE = "SADM - Logistique";

const lt = (displayName, truck) => ({ displayName, truck });

export const CARRIERS = [
  { displayName: "SADM - David", group: "SADM", truck: "62" },
  { displayName: "SADM - Éric", group: "SADM", truck: "43" },
  { displayName: "SADM - Jayson", group: "SADM", truck: "45" },
  { displayName: "SADM - Mathieu", group: "SADM", truck: "54" },
  { displayName: "SADM - Quai2go", group: "SADM", truck: "63" },
  { displayName: "SADM - Steve", group: "SADM", truck: "44" },
  { displayName: "Gat - Sam", group: "Gatineau", truck: "64" },
  { displayName: "Lindsay - Brendan", group: "Lindsay", truck: "66" },
  { displayName: "Lindsay - Cole", group: "Lindsay", truck: "67" },
  { displayName: "Lindsay - Laurent", group: "Lindsay", truck: "68" },
  { displayName: "Mt-Laurier - Steve", group: "Mt-Laurier", truck: "69" },
  { displayName: "Québec - Justin", group: "Québec", truck: "70" },
  { displayName: "Québec - Marc", group: "Québec", truck: "71" },
  { displayName: "Sherbrooke - Hervé", group: "Sherbrooke", truck: "72" },
  {
    displayName: "InterQL", group: "Gooseneck", truck: "3", backendUsername: "RIDEAU GOOSENECK",
    linkedTrucks: [lt("OPEN GOOSENECK", "4")],
  },
  { displayName: "DA TRANSPORT", group: "Externe", truck: "58" },
  { displayName: "LANCEZ TRANSPORT", group: "Externe", truck: "59" },
  { displayName: "SD PRESTIGE", group: "Externe", truck: "73" },
  {
    displayName: LOGISTIQUE, group: "SADM", truck: "62", backendUsername: "SADM - David",
    linkedTrucks: [
      lt("SADM - Éric", "43"), lt("SADM - Jayson", "45"), lt("SADM - Mathieu", "54"),
      lt("SADM - Quai2go", "63"), lt("SADM - Steve", "44"),
      lt("RIDEAU GOOSENECK", "3"), lt("OPEN GOOSENECK", "4"),
    ],
  },
];

export const carrierByName = (name) => CARRIERS.find((c) => c.displayName === name);
export const backendUsername = (c) => c.backendUsername ?? c.displayName;

/** Linked trucks the client actually signs in to (Logistique: Gooseneck only). */
export function loadableLinked(c) {
  const linked = c.linkedTrucks ?? [];
  return c.displayName === LOGISTIQUE ? linked.filter((t) => /GOOSENECK/i.test(t.displayName)) : linked;
}

/** One backend account per truck, de-duplicated (same as carrierAccounts() in Dart). */
export function allAccounts() {
  const seen = new Set();
  const out = [];
  for (const c of CARRIERS) {
    const rows = [
      { username: backendUsername(c), truck: c.truck, owner: c },
      ...(c.linkedTrucks ?? []).map((t) => ({ username: t.displayName, truck: t.truck, owner: c })),
    ];
    for (const r of rows) if (!seen.has(r.username)) { seen.add(r.username); out.push(r); }
  }
  return out;
}
