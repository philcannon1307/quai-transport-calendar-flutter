/// Session storage with the retired-account guard ported from the reference app.
///
/// Pluggable so unit tests run without Flutter plugins; the web/mobile app
/// swaps in a shared_preferences-backed implementation.
abstract class SessionStore {
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
const String kTransferLocationsKey = "transfer_locations";
const String kSuperToken = "__SUPERUSER__";
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
      return null;
    }
    return store.read(kTokenKey);
  }

  String? name() => store.read(kNameKey);
  bool get isSuperUser => store.read(kTokenKey) == kSuperToken;
  void signOut() => store.clear();
}
