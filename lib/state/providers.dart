import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/api_client.dart";
import "../api/auth_service.dart";
import "../api/session.dart";
import "../i18n/i18n.dart";
import "../models/order.dart";

final localeProvider = StateProvider<Locale>((ref) => const Locale("fr"));

/// Loads the ARB dictionary once per locale (not on every widget rebuild).
final stringsProvider = FutureProvider<Strings>((ref) async {
  final locale = ref.watch(localeProvider);
  return Strings.load(locale);
});

final sessionStoreProvider = Provider<SessionStore>((ref) => MemorySessionStore());

final sessionProvider = Provider<Session>((ref) => Session(ref.watch(sessionStoreProvider)));

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// Server-side token exchange endpoint. Empty until the Railway side exists.
/// Injected at runtime; never a secret in the bundle.
final exchangeUrlProvider = Provider<String>((ref) => const String.fromEnvironment("QUAI_EXCHANGE_URL"));

final authServiceProvider = Provider<AuthService>((ref) {
  final url = ref.watch(exchangeUrlProvider);
  if (url.isEmpty) return UnimplementedAuthService();
  return TokenExchangeAuthService(
    exchangeUrl: url,
    post: (u, body) async => throw AuthFailure("Transport not wired yet"),
  );
});

/// Signed-in carrier display name, or null.
final currentCarrierProvider = StateProvider<String?>((ref) => null);

/// Orders for the signed-in session. Empty while the backend exchange is pending —
/// deliberately NOT seeded with sample data, so an empty calendar always means
/// "no data from the backend" rather than "here is something that looks real".
final ordersProvider = FutureProvider<List<Order>>((ref) async {
  final token = ref.watch(sessionProvider).token();
  if (token == null) return <Order>[];
  final api = ref.watch(apiClientProvider);
  final name = ref.watch(currentCarrierProvider);
  final orders = await api.fetchShipCalendarOrders(token, carrierName: name);
  final transfers = await api.fetchTransferOrders(token, carrierName: name);
  return <Order>[...orders, ...transfers];
});

/// Calendar span: 7 or 14 days.
final spanDaysProvider = StateProvider<int>((ref) => 7);

/// "Mes commandes" window: 1 or 2 weeks.
final upcomingWeeksProvider = StateProvider<int>((ref) => 1);
