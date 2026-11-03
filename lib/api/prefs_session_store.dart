import "dart:async";

import "package:shared_preferences/shared_preferences.dart";

import "session.dart";

/// Persistent session storage (localStorage on web, platform prefs on mobile).
///
/// Holds access tokens, the display name, the exchange-issued role and session
/// JWT, and caches. It must NEVER receive a password or carrier code: the client
/// does not keep them (the exchange response is the only thing stored).
///
/// SharedPreferences updates its in-memory copy synchronously, so a write is
/// readable immediately; persistence to storage completes in the background.
class PrefsSessionStore implements SessionStore {
  PrefsSessionStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? read(String key) {
    try {
      return _prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String key, String value) => unawaited(_prefs.setString(key, value));

  @override
  void remove(String key) => unawaited(_prefs.remove(key));

  @override
  void clear() => unawaited(_prefs.clear());
}
