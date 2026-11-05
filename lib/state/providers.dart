import "dart:async";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:url_launcher/url_launcher.dart";

import "../api/api_client.dart";
import "../api/adjustment_service.dart";
import "../api/admin_aggregate.dart";
import "../api/announcements_service.dart";
import "../api/auth_service.dart";
import "../api/backend_gateway.dart";
import "../api/history_service.dart";
import "../api/receipts_service.dart";
import "../api/sales_order_service.dart";
import "../api/supabase_rest_gateway.dart";
import "../api/unsubscribe_service.dart";
import "../logic/announcements.dart";
import "../logic/delivery_history.dart";
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
  (ref) =>
      throw StateError("preloadedStringsProvider must be overridden in main()"),
);

/// Loads the ARB dictionary once per locale (not on every widget rebuild).
final stringsProvider = FutureProvider<Strings>((ref) async {
  final locale = ref.watch(localeProvider);
  return Strings.load(locale);
});

final sessionStoreProvider =
    Provider<SessionStore>((ref) => MemorySessionStore());

final sessionProvider =
    Provider<Session>((ref) => Session(ref.watch(sessionStoreProvider)));

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// Server-side token exchange endpoint. Empty until the Railway side exists.
/// Injected at runtime; never a secret in the bundle.
final exchangeUrlProvider = Provider<String>(
    (ref) => const String.fromEnvironment("QUAI_EXCHANGE_URL"));

final authServiceProvider = Provider<AuthService>((ref) {
  final url = ref.watch(exchangeUrlProvider);
  if (url.isEmpty) return UnimplementedAuthService();
  final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30)));
  return TokenExchangeAuthService(
    exchangeUrl: url,
    post: (u, body) async {
      final Response<dynamic> res;
      try {
        res = await dio.post<dynamic>(u,
            data: body, options: Options(validateStatus: (_) => true));
      } on DioException {
        throw AuthFailure("Connexion impossible. / Cannot connect.");
      }
      final status = res.statusCode ?? 0;
      if (status == 401 || status == 403)
        throw AuthFailure("Identifiants incorrects. / Incorrect credentials.");
      final data = res.data;
      if (status >= 400 || data is! Map)
        throw AuthFailure("Connexion impossible. / Cannot connect.");
      return data.cast<String, dynamic>();
    },
  );
});

/// Signed-in carrier display name, or null.
final currentCarrierProvider = StateProvider<String?>((ref) {
  // Restored from the persisted session, so a page refresh or a deep link keeps
  // the signed-in carrier.
  final s = ref.read(sessionProvider);
  return s.token() == null ? null : s.name();
});

/// True after the backend rejected the session token (401/403): the session was
/// cleared and the login screen explains why.
final sessionExpiredProvider = StateProvider<bool>((ref) => false);

// --- Orders -----------------------------------------------------------------

/// Pick-ups proxy URL (the x-api-key stays on the server). Derived from QUAI_EXCHANGE_URL, so
/// one dart-define configures sign-in and pick-ups; QUAI_MIDDLEWARE_PROXY_URL overrides it.
final middlewareProxyUrlProvider =
    Provider<String>((ref) => middlewareProxyUrlFor(
          exchangeUrl: ref.watch(exchangeUrlProvider),
          override: const String.fromEnvironment("QUAI_MIDDLEWARE_PROXY_URL"),
        ));

final middlewareSourceProvider = Provider<MiddlewareSource>((ref) {
  final url = ref.watch(middlewareProxyUrlProvider);
  if (url.isEmpty) return const UnconfiguredMiddlewareSource();
  final session = ref.watch(sessionProvider);
  // The SESSION JWT (role claim), not the job-service token: the proxy verifies it.
  return ProxyMiddlewareSource(proxyUrl: url, token: session.sessionToken);
});

final ordersRepositoryProvider = Provider<OrdersRepository>(
  (ref) => OrdersRepository(
      api: ref.watch(apiClientProvider),
      middleware: ref.watch(middlewareSourceProvider)),
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
  if (load.unauthorized) {
    // 401/403 from the job service: the token expired. Never show this as an
    // empty calendar; clear the session and send the user to sign in again.
    session.signOut();
    ref.read(sessionExpiredProvider.notifier).state = true;
    ref.read(currentCarrierProvider.notifier).state = null;
    return load;
  }
  session.rememberToTokens(load.toTokens);
  // Mirror what we just loaded into delivery_history (best effort, never blocks).
  unawaited(ref.read(historyServiceProvider).snapshot(load.orders));
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
final logistiqueViewProvider =
    StateProvider<CalendarViewKind>((ref) => CalendarViewKind.delivInst);

// --- Picking tickets and contacts ---------------------------------------------

class SessionTicketTokens implements TicketTokens {
  SessionTicketTokens(this.session);
  final Session session;

  @override
  String? primaryToken() => session.token();

  @override
  String? transferToken(String toNum) =>
      session.toTokens()[toNum.toUpperCase()] ?? session.toTokens()[toNum];

  @override
  String? carrierName() => session.name();

  @override
  List<String> sadmTruckTokens() {
    if (session.name() != kLogistique) return <String>[];
    // SADM trucks first (cheap, most likely owners), then the Gooseneck trucks: Logistique loads the
    // Gooseneck calendars too, so a sales order owned by a Gooseneck truck only opens with THAT token.
    final gooseneck = RegExp("GOOSENECK", caseSensitive: false);
    final entries = session.linkedTokens().entries.toList();
    return <String>[
      ...entries.where((e) => !gooseneck.hasMatch(e.key)).map((e) => e.value),
      ...entries.where((e) => gooseneck.hasMatch(e.key)).map((e) => e.value),
    ];
  }
}

final ticketServiceProvider = Provider<TicketService>(
  (ref) => TicketService(
    fetch: ref.watch(apiClientProvider).fetchTicketRaw,
    tokens: SessionTicketTokens(ref.watch(sessionProvider)),
  ),
);

/// Provisional picking list source (orders with no truck yet). Null for anyone but
/// SADM - Logistique and SuperUser: carriers never get it (the server refuses them too).
final salesOrderServiceProvider = Provider<SalesOrderService?>((ref) {
  final session = ref.watch(sessionProvider);
  final name = session.name();
  if (name != kLogistique && name != kSuperUserName) return null;
  final url = salesOrderUrlFor(ref.watch(middlewareProxyUrlProvider));
  if (url.isEmpty) return null;
  return SalesOrderService(url: url, token: session.sessionToken);
});

/// Reads PDF text. The real engine is injected from main.dart.
final pdfTextExtractorProvider =
    Provider<PdfTextExtractor>((ref) => const UnavailablePdfTextExtractor());

final contactServiceProvider = Provider<ContactService>(
  (ref) => ContactService(
    fetchTicket: ref.watch(ticketServiceProvider).getTicket,
    extractor: ref.watch(pdfTextExtractorProvider),
    store: ref.watch(sessionStoreProvider),
  ),
);

/// Ship-to phone + address for an order; null when unknown or not signed in.
final orderContactProvider =
    FutureProvider.family<OrderContact?, String>((ref, soNum) async {
  if (ref.watch(sessionProvider).token() == null) return null;
  return ref.watch(contactServiceProvider).contactFor(soNum);
});

/// Opens tel: and Maps links. Overridden in tests.
final urlLauncherProvider = Provider<Future<void> Function(Uri uri)>(
  (ref) => (uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  },
);

// --- Backend (announcements, receipts, change reports, history, unsubscribe) -------------

/// Data API base URL (the Railway exchange server) and an OPTIONAL public key (only the old Supabase needed one), supplied at build time with --dart-define.
/// Empty = backend features report "not configured" instead of faking success.
final backendUrlProvider =
    Provider<String>((ref) => const String.fromEnvironment("QUAI_BACKEND_URL"));
final backendKeyProvider =
    Provider<String>((ref) => const String.fromEnvironment("QUAI_BACKEND_KEY"));

final backendProvider = Provider<BackendGateway>((ref) {
  final url = ref.watch(backendUrlProvider);
  final key = ref.watch(backendKeyProvider);
  // The key is optional: the Railway data API (QUAI_BACKEND_URL = the exchange server) needs none.
  if (url.isEmpty) return const UnconfiguredBackend();
  return SupabaseRestGateway(
    baseUrl: url,
    anonKey: key,
    sessionToken: () => ref.read(sessionProvider).sessionToken(),
  );
});

final receiptsServiceProvider = Provider<ReceiptsService>(
    (ref) => ReceiptsService(gateway: ref.watch(backendProvider)));
final adjustmentServiceProvider = Provider<AdjustmentService>(
    (ref) => AdjustmentService(gateway: ref.watch(backendProvider)));
final announcementsServiceProvider = Provider<AnnouncementsService>(
    (ref) => AnnouncementsService(gateway: ref.watch(backendProvider)));
final historyServiceProvider = Provider<HistoryService>(
    (ref) => HistoryService(gateway: ref.watch(backendProvider)));
final unsubscribeServiceProvider = Provider<UnsubscribeService>(
    (ref) => UnsubscribeService(gateway: ref.watch(backendProvider)));

/// Bumped after the SuperUser edits announcements so the banner reloads.
final announcementsRevisionProvider = StateProvider<int>((ref) => 0);

final announcementsProvider = FutureProvider<List<Announcement>>((ref) async {
  ref.watch(announcementsRevisionProvider);
  return ref.watch(announcementsServiceProvider).list();
});

/// History range in days (0 = live only). Valid values: kHistoryRanges.
final historyDaysProvider = StateProvider<int>((ref) => 0);

/// Past deliveries for the signed-in carrier, newest first. Today is excluded.
final pastOrdersProvider = FutureProvider<List<Order>>((ref) async {
  final days = ref.watch(historyDaysProvider);
  if (days <= 0) return <Order>[];
  final session = ref.watch(sessionProvider);
  if (session.token() == null) return <Order>[];
  final name = ref.watch(currentCarrierProvider) ?? session.name() ?? "";
  final names = session.isSuperUser
      ? null
      : historyCarrierNames(carrierByDisplayName(name), name);
  return ref
      .watch(historyServiceProvider)
      .past(days: days, carrierNames: names);
});

/// Server-side cached orders of every truck (GET /admin/orders-aggregate). Null when the SuperUser
/// is not signed in, the server cannot answer, or it has no data yet: the Admin screen then falls
/// back to loading truck by truck. Re-read every minute while the screen is open.
final adminAggregateServiceProvider = Provider<AdminAggregateService?>((ref) {
  final session = ref.watch(sessionProvider);
  if (!session.isSuperUser) return null;
  final url = adminAggregateUrlFor(ref.watch(middlewareProxyUrlProvider));
  if (url.isEmpty) return null;
  return AdminAggregateService(url: url, token: session.sessionToken);
});

final adminAggregateProvider = FutureProvider<AdminAggregate?>((ref) async {
  final service = ref.watch(adminAggregateServiceProvider);
  if (service == null) return null;
  final timer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final agg = await service.fetch();
  return agg != null && agg.hasData ? agg : null;
});

/// True while a manual "Refresh" is waiting for the server.
final adminRefreshingProvider = StateProvider<bool>((ref) => false);

/// Asks the server to refresh now, then re-reads the aggregate until it is done (max ~4 min).
Future<void> refreshAdminAggregate(ProviderContainer ref, {Duration poll = const Duration(seconds: 8), int maxPolls = 30}) async {
  final service = ref.read(adminAggregateServiceProvider);
  if (service == null || ref.read(adminRefreshingProvider)) return;
  ref.read(adminRefreshingProvider.notifier).state = true;
  try {
    final r = await service.requestRefresh();
    if (r == AggregateRefresh.failed || r == AggregateRefresh.rateLimited) {
      ref.invalidate(adminAggregateProvider);
      return;
    }
    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(poll);
      final agg = await service.fetch();
      ref.invalidate(adminAggregateProvider);
      if (agg != null && !agg.refreshing) break;
    }
  } finally {
    ref.read(adminRefreshingProvider.notifier).state = false;
  }
}

/// SuperUser aggregate of every account: the server's cache first (one fast request), and only
/// when that is unavailable the slow per-truck path. Empty unless the session is the SuperUser's.
final adminLoadProvider = FutureProvider<OrdersLoad>((ref) async {
  final session = ref.watch(sessionProvider);
  if (!session.isSuperUser) return const OrdersLoad();
  final cached = await ref.watch(adminAggregateProvider.future);
  if (cached != null) return cached.toOrdersLoad();
  return ref.watch(ordersRepositoryProvider).loadAggregate(
        accounts: carrierAccounts(kCarriers),
        tokensByUsername: session.linkedTokens(),
      );
});

/// Group / location filters on /admin.
final adminGroupProvider = StateProvider<String?>((ref) => null);
final adminLocationProvider = StateProvider<int?>((ref) => null);

/// Sign out: clear the stored session and the in-memory carrier.
void signOutNow(WidgetRef ref) {
  ref.read(sessionProvider).signOut();
  ref.read(currentCarrierProvider.notifier).state = null;
  ref.read(historyDaysProvider.notifier).state = 0;
  ref.read(sessionExpiredProvider.notifier).state = false;
}
