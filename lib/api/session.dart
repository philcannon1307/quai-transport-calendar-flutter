import "dart:convert";

import "../state/session_store_port.dart";

/// Session storage with the retired-account guard ported from the reference app.
///
/// Pluggable so unit tests run without Flutter plugins; the web/mobile app
/// swaps in a shared_preferences-backed implementation.
abstract class SessionStore implements KeyValueStore {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
  void clear();
}

class MemorySessionStore implements SessionStore {
  final Map<String, String> _m = <String, String>{};
  @override
  String? read(String key) => _m[key];
  @override
  void write(String key, String value) => _m[key] = value;
  @override
  void remove(String key) => _m.remove(key);
  @override
  void clear() => _m.clear();
}

const String kTokenKey = "quai_contractor_token";
const String kNameKey = "quai_contractor_name";
const String kSuperKey = "quai_super_orders";
const String kLinkedKey = "quai_linked_orders";

/// Reference app also cached credentials here. The port never writes it; the
/// key is retained only so an old session can be purged on upgrade.
const String kLinkedCredsKey = "quai_linked_creds";
const String kToTokensKey = "quai_to_tokens";

/// username -> access token for each linked truck (from the server-side exchange).
const String kLinkedTokensKey = "quai_linked_tokens";
const String kTransferLocationsKey = "transfer_locations";

/// Role returned by the server-side token exchange. The client NEVER decides it:
/// it is stored from the exchange response and only drives what the UI shows.
/// Enforcement of every privileged action lives on the server (see server-contract.md).
const String kRoleKey = "quai_role";
const String kRoleCarrier = "carrier";
const String kRoleLogistique = "logistique";
const String kRoleSuperUser = "superuser";

/// Signed session JWT issued by the exchange (carries the role claim). Sent to the
/// backend as X-Quai-Session so edge functions can verify who is calling.
const String kSessionTokenKey = "quai_session_token";

bool isKnownRole(String? r) =>
    r == kRoleCarrier || r == kRoleLogistique || r == kRoleSuperUser;

/// Calendar name shown for the SuperUser session.
const String kSuperUserName = "SuperUser";

/// Where logging out sends the user (reference rule).
const String kLogoutUrl = "https://lafantaisie-connect.lovable.app";
const String kLangKey = "quai:lang";

/// Retired Gatineau accounts: any saved session must be dropped.
final RegExp _retired = RegExp(r"solution lac", caseSensitive: false);

class Session {
  Session(this.store);
  final SessionStore store;

  /// Returns the stored token, clearing the session for retired accounts.
  String? token() {
    final name = store.read(kNameKey);
    if (name != null && _retired.hasMatch(name)) {
      store.remove(kTokenKey);
      store.remove(kNameKey);
      store.remove(kLinkedCredsKey);
      store.remove(kLinkedKey);
      store.remove(kSuperKey);
      store.remove(kRoleKey);
      store.remove(kSessionTokenKey);
      return null;
    }
    return store.read(kTokenKey);
  }

  String? name() => store.read(kNameKey);

  /// Role from the exchange response (null when signed out).
  String? role() => token() == null ? null : store.read(kRoleKey);

  /// UI hint only: true when the EXCHANGE said role=superuser. Not a security
  /// boundary; the server verifies the signed session token on every write.
  bool get isSuperUser => role() == kRoleSuperUser;

  /// Signed session JWT for backend calls; falls back to the access token.
  String? sessionToken() => store.read(kSessionTokenKey) ?? token();
  void signOut() => store.clear();

  Map<String, String> _readMap(String key) {
    try {
      final raw = store.read(key);
      if (raw == null) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((k, v) => out[k.toString()] = v.toString());
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  /// Linked-truck tokens, keyed by backend username.
  Map<String, String> linkedTokens() => _readMap(kLinkedTokensKey);

  /// Transfer order number -> token of the Gooseneck truck that owns it.
  Map<String, String> toTokens() => _readMap(kToTokensKey);

  void rememberToTokens(Map<String, String> more) {
    if (more.isEmpty) return;
    store.write(
        kToTokensKey, jsonEncode(<String, String>{...toTokens(), ...more}));
  }

  /// Start a session. Switching calendars must never leak the previous
  /// carrier's cached linked orders, credentials or transfer tokens
  /// (regression from the reference app's interql.test.ts).
  void signIn({
    required String token,
    required String name,
    Map<String, String> linkedTokens = const <String, String>{},
    String role = kRoleCarrier,
    String? sessionToken,
  }) {
    store.remove(kLinkedKey);
    store.remove(kLinkedCredsKey);
    store.remove(kToTokensKey);
    store.remove(kSuperKey);
    store.write(kTokenKey, token);
    store.write(kNameKey, name);
    store.write(kLinkedTokensKey, jsonEncode(linkedTokens));
    store.write(kRoleKey, isKnownRole(role) ? role : kRoleCarrier);
    if (sessionToken != null && sessionToken.isNotEmpty) {
      store.write(kSessionTokenKey, sessionToken);
    } else {
      store.remove(kSessionTokenKey);
    }
  }
}
