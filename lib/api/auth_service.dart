import "../models/carrier.dart";
import "session.dart";

/// Result of a sign-in: one access token per truck the login covers.
class AuthResult {
  const AuthResult({
    required this.primaryToken,
    this.linkedTokens = const <String, String>{},
    this.role = kRoleCarrier,
    this.sessionToken,
  });
  final String primaryToken;

  /// carrier | logistique | superuser, as returned by the server. The client
  /// never derives it locally.
  final String role;

  /// Signed session JWT (role claim, short TTL) for backend calls, if issued.
  final String? sessionToken;
  /// backend username -> access token
  final Map<String, String> linkedTokens;
}

class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sign-in contract.
///
/// SECURITY: the reference app shipped every carrier password in the client
/// bundle (src/lib/carriers.ts) plus a middleware API key (src/lib/api.ts).
/// This port ships NEITHER. The server holds the credential table, calls
/// POST /api/auth/mvp-login itself, and returns only the resulting tokens.
abstract class AuthService {
  Future<AuthResult> signIn({required Carrier carrier, required String code});

  /// SuperUser (/admin) sign-in. The reference app compared a hardcoded
  /// username/password IN THE BROWSER and then logged in as every carrier with
  /// the passwords it also shipped. Here the SERVER checks the credentials and,
  /// on success, returns one access token per backend account in
  /// [AuthResult.linkedTokens] (keyed by backend username). Nothing is checked
  /// or stored client-side.
  Future<AuthResult> signInSuperUser({required String username, required String password});
}

/// Calls the server-side token exchange. Endpoint is injected, never a secret.
class TokenExchangeAuthService implements AuthService {
  // PROPOSED CONTRACT for the SuperUser exchange (same endpoint):
  //   POST <exchangeUrl> {"carrier": "SuperUser", "username": ..., "code": <password>}
  //   -> {"accessToken": "...", "linkedTokens": {"<backend username>": "<token>", ...},
  //       "role": "superuser", "sessionToken": "<signed JWT, role claim>"}
  // linkedTokens must hold a token for EVERY backend account; 401/403 on a bad login.
  TokenExchangeAuthService({required this.exchangeUrl, required this.post});

  final String exchangeUrl;
  /// Injected transport so this stays unit-testable: body -> decoded JSON.
  final Future<Map<String, dynamic>> Function(String url, Map<String, dynamic> body) post;

  @override
  Future<AuthResult> signInSuperUser({required String username, required String password}) async {
    if (exchangeUrl.isEmpty) {
      throw AuthFailure("NOT_CONFIGURED: server-side token exchange endpoint is not set.");
    }
    final json = await post(exchangeUrl, <String, dynamic>{
      "carrier": kSuperUserName,
      "username": username,
      "code": password,
    });
    final linked = <String, String>{};
    final rawLinked = json["linkedTokens"];
    if (rawLinked is Map) {
      rawLinked.forEach((k, v) {
        if (v is String && v.isNotEmpty) linked[k.toString()] = v;
      });
    }
    if (linked.isEmpty) throw AuthFailure("Invalid response from token exchange.");
    // SuperUser is whatever the SERVER says: a response without role=superuser is
    // rejected, so a misbehaving endpoint cannot grant the admin UI.
    if (json["role"] != kRoleSuperUser) throw AuthFailure("Invalid response from token exchange.");
    final primary = json["accessToken"];
    final jwt = json["sessionToken"];
    return AuthResult(
      primaryToken: primary is String ? primary : "",
      linkedTokens: linked,
      role: kRoleSuperUser,
      sessionToken: jwt is String && jwt.isNotEmpty ? jwt : null,
    );
  }

  @override
  Future<AuthResult> signIn({required Carrier carrier, required String code}) async {
    if (exchangeUrl.isEmpty) {
      throw AuthFailure("NOT_CONFIGURED: server-side token exchange endpoint is not set.");
    }
    final json = await post(exchangeUrl, <String, dynamic>{
      "carrier": carrier.displayName,
      "code": code,
    });
    final token = json["accessToken"];
    if (token is! String || token.isEmpty) throw AuthFailure("Invalid response from token exchange.");
    final linked = <String, String>{};
    final rawLinked = json["linkedTokens"];
    if (rawLinked is Map) {
      rawLinked.forEach((k, v) {
        if (v is String) linked[k.toString()] = v;
      });
    }
    final role = json["role"];
    final jwt = json["sessionToken"];
    return AuthResult(
      primaryToken: token,
      linkedTokens: linked,
      role: role is String && isKnownRole(role) ? role : kRoleCarrier,
      sessionToken: jwt is String && jwt.isNotEmpty ? jwt : null,
    );
  }
}

/// Placeholder used until the Railway-side exchange exists.
///
/// It deliberately FAILS LOUDLY instead of faking a signed-in session, so a
/// missing backend can never be mistaken for a working login.
class UnimplementedAuthService implements AuthService {
  @override
  Future<AuthResult> signInSuperUser({required String username, required String password}) async {
    throw AuthFailure(
      "PENDING_BACKEND: the server-side token exchange is not deployed yet. "
      "The SuperUser login cannot work until it exists.",
    );
  }

  @override
  Future<AuthResult> signIn({required Carrier carrier, required String code}) async {
    throw AuthFailure(
      "PENDING_BACKEND: the server-side token exchange is not deployed yet. "
      "The Railway job service credentials must move server-side before sign-in can work.",
    );
  }
}
