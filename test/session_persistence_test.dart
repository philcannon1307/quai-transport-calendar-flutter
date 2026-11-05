import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:quai_calendar/api/auth_service.dart";
import "package:quai_calendar/api/prefs_session_store.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/data/carriers.dart";

void main() {
  group("persistent session store", () {
    test("a session survives a reload (new Session over the same storage)",
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      Session(PrefsSessionStore(prefs)).signIn(
        token: "tok-1",
        name: "InterQL",
        linkedTokens: <String, String>{"OPEN GOOSENECK": "tok-4"},
        role: kRoleCarrier,
        sessionToken: "jwt-1",
      );
      // "Reload": a brand-new Session reading the same persisted storage.
      final reloaded = Session(PrefsSessionStore(prefs));
      expect(reloaded.token(), "tok-1");
      expect(reloaded.name(), "InterQL");
      expect(
          reloaded.linkedTokens(), <String, String>{"OPEN GOOSENECK": "tok-4"});
      expect(reloaded.role(), kRoleCarrier);
      expect(reloaded.sessionToken(), "jwt-1");
      expect(prefs.getString(kTokenKey), "tok-1");
    });

    test("only tokens, name and role are stored: never a credential", () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      Session(PrefsSessionStore(prefs))
          .signIn(token: "t", name: "SADM - David", sessionToken: "j");
      final allowed = <String>{
        kTokenKey,
        kNameKey,
        kLinkedTokensKey,
        kRoleKey,
        kSessionTokenKey
      };
      expect(prefs.getKeys().difference(allowed), isEmpty);
      for (final k in prefs.getKeys()) {
        expect(k.toLowerCase(), isNot(contains("password")));
        expect(k.toLowerCase(), isNot(contains("code")));
      }
    });

    test("logout clears everything, so a reload is signed out", () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final s = Session(PrefsSessionStore(prefs))
        ..signIn(token: "t", name: "InterQL");
      s.signOut();
      expect(prefs.getKeys(), isEmpty);
      expect(Session(PrefsSessionStore(prefs)).token(), isNull);
    });

    test("a retired account is purged from a restored session", () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kTokenKey: "t",
        kNameKey: "Solution Lac - X",
        kRoleKey: kRoleCarrier
      });
      final prefs = await SharedPreferences.getInstance();
      expect(Session(PrefsSessionStore(prefs)).token(), isNull);
      expect(prefs.getString(kRoleKey), isNull);
    });
  });

  group("role comes from the exchange response", () {
    test("isSuperUser follows the stored server role, not the token value", () {
      final carrier = Session(MemorySessionStore())
        ..signIn(token: "__SUPERUSER__", name: "SuperUser");
      expect(carrier.isSuperUser, isFalse,
          reason: "a token string never grants the role");
      final admin = Session(MemorySessionStore())
        ..signIn(token: "t", name: kSuperUserName, role: kRoleSuperUser);
      expect(admin.isSuperUser, isTrue);
      expect(admin.role(), kRoleSuperUser);
    });

    test("an unknown role is stored as carrier", () {
      final s = Session(MemorySessionStore())
        ..signIn(token: "t", name: "InterQL", role: "root");
      expect(s.role(), kRoleCarrier);
      expect(s.isSuperUser, isFalse);
    });

    test("signed out means no role even if a stale role key remains", () {
      final store = MemorySessionStore()..write(kRoleKey, kRoleSuperUser);
      expect(Session(store).isSuperUser, isFalse);
    });

    test("SuperUser sign-in is rejected unless the server says role=superuser",
        () async {
      final svc = TokenExchangeAuthService(
        exchangeUrl: "https://x/exchange",
        post: (u, b) async => <String, dynamic>{
          "accessToken": "a",
          "linkedTokens": <String, String>{"RIDEAU GOOSENECK": "t3"}
        },
      );
      expect(() => svc.signInSuperUser(username: "u", password: "p"),
          throwsA(isA<AuthFailure>()));
    });

    test("SuperUser sign-in keeps the server role and the session JWT",
        () async {
      final svc = TokenExchangeAuthService(
        exchangeUrl: "https://x/exchange",
        post: (u, b) async => <String, dynamic>{
          "accessToken": "a",
          "linkedTokens": <String, String>{"RIDEAU GOOSENECK": "t3"},
          "role": "superuser",
          "sessionToken": "jwt",
        },
      );
      final r = await svc.signInSuperUser(username: "u", password: "p");
      expect(r.role, kRoleSuperUser);
      expect(r.sessionToken, "jwt");
    });

    test("carrier sign-in reads role and JWT, defaulting to carrier", () async {
      final carrier = carrierByDisplayName("InterQL")!;
      final withRole = TokenExchangeAuthService(
        exchangeUrl: "https://x/exchange",
        post: (u, b) async => <String, dynamic>{
          "accessToken": "a",
          "role": "logistique",
          "sessionToken": "j"
        },
      );
      final r1 = await withRole.signIn(carrier: carrier, code: "123456");
      expect(r1.role, kRoleLogistique);
      expect(r1.sessionToken, "j");
      final without = TokenExchangeAuthService(
          exchangeUrl: "https://x/exchange",
          post: (u, b) async => <String, dynamic>{"accessToken": "a"});
      expect((await without.signIn(carrier: carrier, code: "123456")).role,
          kRoleCarrier);
    });
  });
}
