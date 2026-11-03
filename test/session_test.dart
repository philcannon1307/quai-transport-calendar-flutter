import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/session.dart";

void main() {
  test("switching calendars clears the previous carrier's cached linked data", () {
    final store = MemorySessionStore()
      ..write(kLinkedKey, "old linked orders")
      ..write(kLinkedCredsKey, "old linked credentials")
      ..write(kToTokensKey, "{\"TO1\":\"old\"}");
    Session(store).signIn(token: "new-token", name: "Gat - Sam");
    expect(store.read(kLinkedKey), isNull);
    expect(store.read(kLinkedCredsKey), isNull);
    expect(store.read(kToTokensKey), isNull);
    expect(store.read(kTokenKey), "new-token");
    expect(store.read(kNameKey), "Gat - Sam");
  });

  test("linked-truck tokens are stored and read back", () {
    final session = Session(MemorySessionStore());
    session.signIn(token: "t", name: "InterQL", linkedTokens: <String, String>{"OPEN GOOSENECK": "t4"});
    expect(session.linkedTokens(), <String, String>{"OPEN GOOSENECK": "t4"});
  });

  test("transfer owner tokens accumulate across refreshes", () {
    final session = Session(MemorySessionStore());
    session.rememberToTokens(<String, String>{"TO1": "a"});
    session.rememberToTokens(<String, String>{"TO2": "b"});
    expect(session.toTokens(), <String, String>{"TO1": "a", "TO2": "b"});
  });

  test("a second sign-in does not inherit the first one's linked tokens", () {
    final session = Session(MemorySessionStore());
    session.signIn(token: "t", name: "InterQL", linkedTokens: <String, String>{"OPEN GOOSENECK": "t4"});
    session.signIn(token: "u", name: "Gat - Sam");
    expect(session.linkedTokens(), isEmpty);
  });

  test("corrupt stored token maps read as empty instead of crashing", () {
    final store = MemorySessionStore()..write(kLinkedTokensKey, "{nope");
    expect(Session(store).linkedTokens(), isEmpty);
  });

  test("retired accounts are still purged on read", () {
    final store = MemorySessionStore();
    final session = Session(store);
    session.signIn(token: "t", name: "Solution Lac - Bob");
    expect(session.token(), isNull);
  });
}
