import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:url_launcher/url_launcher.dart";

import "../api/api_client.dart";
import "../api/auth_service.dart";
import "../api/contact_service.dart";
import "../api/middleware_source.dart";
import "../api/orders_repository.dart";
import "../api/session.dart";
import "../api/ticket_service.dart";
import "../data/carriers.dart";
import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../logic/contact_parser.dart";
import "../models/order.dart";

final localeProvider = StateProvider<Locale>((ref) => const Locale("fr"));

/// The dictionary loaded in main() before runApp. Overridden in ProviderScope;
/// reading it without that override is a programming error.
final preloadedStringsProvider = Provider<Strings>(
  (ref) => throw StateError("preloadedStringsProvider must be overridden in main()"),
);

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

// --- Orders -----------------------------------------------------------------

/// Middleware proxy URL (holds the x-api-key server-side). Empty until it exists.
final middlewareProxyUrlProvider =
    Provider<String>((ref) => const String.fromEnvironment("QUAI_MIDDLEWARE_PROXY_URL"));

final middlewareSourceProvider = Provider<MiddlewareSource>((ref) {
  final url = ref.watch(middlewareProxyUrlProvider);
  if (url.isEmpty) return const UnconfiguredMiddlewareSource();
  final session = ref.watch(sessionProvider);
  return ProxyMiddlewareSource(proxyUrl: url, token: session.token);
});

final ordersRepositoryProvider = Provider<OrdersRepository>(
  (ref) => OrdersRepository(api: ref.watch(apiClientProvider), middleware: ref.watch(middlewareSourceProvider)),
);

/// Orders for the signed-in session plus what could not be loaded.
/// Empty while there is no session — deliberately NOT seeded with sample data,
/// so an empty calendar always means "no data from the backend".
final ordersLoadProvider = FutureProvider<OrdersLoad>((ref) async {
  final session = ref.watch(sessionProvider);
  final token = session.token();
  if (token == null) return const OrdersLoad();
  final name = ref.watch(currentCarrierProvider) ?? session.name() ?? "";
  final load = await ref.watch(ordersRepositoryProvider).load(
        carrier: carrierByDisplayName(name),
        carrierName: name,
        primaryToken: token,
        linkedTokens: session.linkedTokens(),
      );
  session.rememberToTokens(load.toTokens);
  return load;
});

/// Just the cards. Screens read this; tests override it with plain lists.
final ordersProvider = FutureProvider<List<Order>>((ref) async {
  final load = await ref.watch(ordersLoadProvider.future);
  return load.orders;
});

/// Calendar span: 7 or 14 days.
final spanDaysProvider = StateProvider<int>((ref) => 7);

/// "Mes commandes" window: 1 or 2 weeks.
final upcomingWeeksProvider = StateProvider<int>((ref) => 1);

/// SADM - Logistique's selected tab.
final logistiqueViewProvider = StateProvider<CalendarViewKind>((ref) => CalendarViewKind.delivInst);

// --- Picking tickets and contacts ---------------------------------------------

class SessionTicketTokens implements TicketTokens {
  SessionTicketTokens(this.session);
  final Session session;

  @override
  String? primaryToken() => session.token();

  @override
  String? transferToken(String toNum) => session.toTokens()[toNum.toUpperCase()] ?? session.toTokens()[toNum];

  @override
  String? carrierName() => session.name();

  @override
  List<String> sadmTruckTokens() {
    if (session.name() != kLogistique) return <String>[];
    final gooseneck = RegExp("GOOSENECK", caseSensitive: false);
    return session.linkedTokens().entries.where((e) => !gooseneck.hasMatch(e.key)).map((e) => e.value).toList();
  }
}

final ticketServiceProvider = Provider<TicketService>(
  (ref) => TicketService(
    fetch: ref.watch(apiClientProvider).fetchTicketRaw,
    tokens: SessionTicketTokens(ref.watch(sessionProvider)),
  ),
);

/// Reads PDF text. The real engine is injected from main.dart.
final pdfTextExtractorProvider = Provider<PdfTextExtractor>((ref) => const UnavailablePdfTextExtractor());

final contactServiceProvider = Provider<ContactService>(
  (ref) => ContactService(
    fetchTicket: ref.watch(ticketServiceProvider).getTicket,
    extractor: ref.watch(pdfTextExtractorProvider),
    store: ref.watch(sessionStoreProvider),
  ),
);

/// Ship-to phone + address for an order; null when unknown or not signed in.
final orderContactProvider = FutureProvider.family<OrderContact?, String>((ref, soNum) async {
  if (ref.watch(sessionProvider).token() == null) return null;
  return ref.watch(contactServiceProvider).contactFor(soNum);
});

/// Opens tel: and Maps links. Overridden in tests.
final urlLauncherProvider = Provider<Future<void> Function(Uri uri)>(
  (ref) => (uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  },
);
