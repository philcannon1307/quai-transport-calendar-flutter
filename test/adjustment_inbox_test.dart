import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/data/carriers.dart";

void main() {
  group("adjustmentInbox", () {
    test("SADM -> sadm", () => expect(adjustmentInbox("SADM - Jayson"), "sadm@groupeql.com"));
    test("Rideau Gooseneck -> sadm", () => expect(adjustmentInbox("RIDEAU GOOSENECK"), "sadm@groupeql.com"));
    test("Open Gooseneck -> sadm", () => expect(adjustmentInbox("OPEN GOOSENECK"), "sadm@groupeql.com"));
    test("InterQL -> sadm", () => expect(adjustmentInbox("InterQL"), "sadm@groupeql.com"));
    test("Gat -> gatineau", () => expect(adjustmentInbox("Gat - Sam"), "gatineau@groupeql.com"));
    test("Lindsay -> lindsay", () => expect(adjustmentInbox("Lindsay - Cole"), "lindsay@groupeql.com"));
    test("Quebec -> quebec", () => expect(adjustmentInbox("Québec - Marc"), "quebec@groupeql.com"));
    test("DA Transport -> quebec", () => expect(adjustmentInbox("DA TRANSPORT"), "quebec@groupeql.com"));
    test("LANCEZ -> quebec", () => expect(adjustmentInbox("LANCEZ TRANSPORT"), "quebec@groupeql.com"));
    test("SD Prestige -> quebec", () => expect(adjustmentInbox("SD PRESTIGE"), "quebec@groupeql.com"));
    test("Sherbrooke -> estrie", () => expect(adjustmentInbox("Sherbrooke - Hervé"), "estrie@groupeql.com"));
    test("Mt-Laurier -> mt-laurier", () => expect(adjustmentInbox("Mt-Laurier - Steve"), "mt-laurier@groupeql.com"));
  });

  group("transfer change reports", () {
    test("TO Ste-Agathe -> Lindsay goes to both stores", () {
      expect(adjustmentRecipients("InterQL", <String>["Ste-Agathe", "Lindsay"]), <String>["sadm@groupeql.com", "lindsay@groupeql.com"]);
    });
    test("TO Ste-Agathe -> Quebec goes to both stores", () {
      expect(adjustmentRecipients("InterQL", <String>["Sainte-Agathe", "Québec"]), <String>["sadm@groupeql.com", "quebec@groupeql.com"]);
    });
    test("sales order keeps the carrier group inbox", () {
      expect(adjustmentRecipients("Lindsay - Cole"), <String>["lindsay@groupeql.com"]);
    });
  });
}
