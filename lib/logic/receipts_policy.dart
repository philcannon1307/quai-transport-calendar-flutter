import "../data/carriers.dart";

/// Who sees the REÇUS / BOL button. Ported VERBATIM from RECEIPTS_ALLOWED in the
/// reference Dashboard.tsx (note: "SADM - Quai2go" is deliberately absent).
const Set<String> kReceiptsAllowed = <String>{
  "SADM - David",
  "SADM - Éric",
  "SADM - Jayson",
  "SADM - Mathieu",
  "SADM - Steve",
  "Gat - Sam",
  "InterQL",
  "Lindsay - Brendan",
  "Lindsay - Cole",
  "Lindsay - Laurent",
  "Mt-Laurier - Steve",
  "Québec - Justin",
  "Québec - Marc",
  "Sherbrooke - Hervé",
  kLogistique,
};

/// The SuperUser sees the button too; everyone else only if allowlisted.
bool canUploadReceipts(String? carrierName, {required bool isSuperUser}) =>
    isSuperUser ||
    (carrierName != null && kReceiptsAllowed.contains(carrierName));

/// SADM - Logistique uploads a bill of lading (BOL, emailed to sadm@groupeql.com);
/// everyone else uploads a receipt (emailed to comptabilite@groupeql.com).
/// The RECIPIENT is fixed server-side by the email template, never chosen here.
bool isBolMode(String? carrierName) => carrierName == kLogistique;

String receiptTemplateName({required bool bol}) =>
    bol ? "bol-uploaded" : "receipt-uploaded";
