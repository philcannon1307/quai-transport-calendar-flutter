import "../data/carriers.dart";
import "../logic/middleware_events.dart";
import "../models/carrier.dart";
import "../models/order.dart";
import "middleware_source.dart";
import "orders_api.dart";

/// Everything one refresh produced, including what could NOT be loaded, so the
/// UI can say so instead of silently showing a shorter calendar.
class OrdersLoad {
  const OrdersLoad({
    this.orders = const <Order>[],
    this.toTokens = const <String, String>{},
    this.failedTrucks = const <String>[],
    this.unauthorized = false,
    this.middlewareUnavailable = false,
  });

  final List<Order> orders;

  /// Transfer order number -> token of the Gooseneck truck that owns it.
  final Map<String, String> toTokens;

  /// Trucks whose orders could not be loaded (missing token or request failed).
  final List<String> failedTrucks;

  /// At least one token was rejected (401/403): sign in again.
  final bool unauthorized;

  /// Logistique pick-ups need the middleware proxy and none is configured.
  final bool middlewareUnavailable;
}

/// Loads and merges every source a calendar needs. Ported from fetchOrders /
/// fetchLinkedOrders in api.ts, minus the parts that need credentials: this
/// class receives ready-made tokens and never signs in.
/// The only calendar location SADM - Logistique may request (SADM = Ste-Agathe).
const String kLogistiqueLocation = "Ste-Agathe";

class OrdersRepository {
  OrdersRepository(
      {required this.api, required this.middleware, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final OrdersApi api;
  final MiddlewareSource middleware;
  final DateTime Function() _clock;

  static final RegExp _transferAccounts =
      RegExp("GOOSENECK", caseSensitive: false);

  /// Linked trucks may share one SO (separate events per truck), so identity is
  /// the EVENT when there is one, never the SO number alone.
  static String orderKey(Order o) {
    if (o.serviceEventId != null) return "event:${o.serviceEventId}";
    final id = (o.soId != null && o.soId != 0) ? o.soId.toString() : o.soNum;
    return "so:$id";
  }

  Future<OrdersLoad> load({
    required Carrier? carrier,
    required String carrierName,
    required String primaryToken,
    Map<String, String> linkedTokens = const <String, String>{},
  }) async {
    final isLogistique = carrier?.displayName == kLogistique;
    final backendName = carrier?.backendUsername ?? carrierName;
    final toTokens = <String, String>{};
    final failed = <String>[];
    var unauthorized = false;

    void rememberTransfers(List<Order> transfers, String token) {
      for (final t in transfers) {
        if (t.isTransfer) toTokens[t.soNum.toUpperCase()] = token;
      }
    }

    // SADM - Logistique gets its SADM jobs from the middleware, so it skips the
    // slow per-truck ship-calendar call for its own login entirely.
    Future<List<Order>> primary() async {
      if (isLogistique) return <Order>[];
      try {
        final orders =
            await api.shipOrders(primaryToken, carrierName: carrierName);
        final out = <Order>[...orders];
        if (_transferAccounts.hasMatch(backendName)) {
          final transfers =
              await api.transferOrders(primaryToken, carrierName: carrierName);
          rememberTransfers(transfers, primaryToken);
          out.addAll(transfers);
        }
        return out;
      } on UnauthorizedException {
        unauthorized = true;
        failed.add(carrierName);
        return <Order>[];
      } catch (_) {
        failed.add(carrierName);
        return <Order>[];
      }
    }

    Future<List<Order>> linked(LinkedTruck lt) async {
      final token = linkedTokens[lt.displayName];
      if (token == null) {
        failed.add(lt.displayName);
        return <Order>[];
      }
      final name = calendarName(lt.displayName);
      try {
        final results = await Future.wait<List<Order>>(<Future<List<Order>>>[
          api.shipOrders(token, carrierName: name),
          _transferAccounts.hasMatch(lt.displayName)
              ? api.transferOrders(token, carrierName: name)
              : Future<List<Order>>.value(<Order>[]),
        ]);
        rememberTransfers(results[1], token);
        // Each linked truck's jobs belong to that truck's calendar name.
        return <Order>[...results[0], ...results[1]]
            .map((o) => o.withCarrierName(name))
            .toList();
      } on UnauthorizedException {
        unauthorized = true;
        failed.add(lt.displayName);
        return <Order>[];
      } catch (_) {
        failed.add(lt.displayName);
        return <Order>[];
      }
    }

    Future<List<Order>> fromMiddleware() async {
      if (!isLogistique) return <Order>[];
      final now = _clock();
      // SADM - Logistique sees ONLY SADM (Ste-Agathe) orders, never other locations.
      final events = await middleware.events(
        kLogistiqueLocation,
        from: now.subtract(const Duration(days: 14)),
        to: now.add(const Duration(days: 60)),
      );
      return events.map(mapMiddlewareEvent).whereType<Order>().toList();
    }

    final linkedTrucks = loadableLinkedTrucks(carrier);
    final results = await Future.wait<List<Order>>(<Future<List<Order>>>[
      primary(),
      ...linkedTrucks.map(linked),
      fromMiddleware(),
    ]);

    Order tag(Order o) =>
        o.withCarrierName(calendarName(o.carrierName ?? carrierName));

    final merged = <Order>[];
    final seen = <String>{};
    final seenSoDate = <String>{};
    void add(Order o) {
      seen.add(orderKey(o));
      seenSoDate.add("${o.soNum}|${o.date}");
      merged.add(tag(o));
    }

    // Primary: kept as delivered.
    for (final o in results.first) {
      add(o);
    }
    // Linked trucks: de-duplicate by EVENT only, never by SO number.
    for (var i = 1; i <= linkedTrucks.length; i++) {
      for (final o in results[i]) {
        if (seen.contains(orderKey(o))) continue;
        add(o);
      }
    }
    // Middleware events duplicate ship-calendar orders, so de-duplicate by SO + date.
    for (final o in results.last) {
      if (seen.contains(orderKey(o)) ||
          seenSoDate.contains("${o.soNum}|${o.date}")) continue;
      add(o);
    }

    return OrdersLoad(
      orders: merged,
      toTokens: toTokens,
      failedTrucks: failed,
      unauthorized: unauthorized,
      middlewareUnavailable: isLogistique && !middleware.configured,
    );
  }

  /// SuperUser view: every account's orders aggregated WITHOUT signing in as the
  /// shared logins (InterQL is represented by its two trucks, 3 and 4).
  /// [tokensByUsername] holds one token per backend username.
  Future<OrdersLoad> loadAggregate({
    required List<CarrierAccount> accounts,
    required Map<String, String> tokensByUsername,
  }) async {
    final failed = <String>[];
    final toTokens = <String, String>{};
    var unauthorized = false;

    final lists = await Future.wait<List<Order>>(accounts.map((a) async {
      final token = tokensByUsername[a.username];
      if (token == null) {
        failed.add(a.username);
        return <Order>[];
      }
      final name = calendarName(a.displayName);
      try {
        final ship = await api.shipOrders(token, carrierName: name);
        final transfers = _transferAccounts.hasMatch(a.username)
            ? await api.transferOrders(token, carrierName: name)
            : <Order>[];
        for (final t in transfers) {
          if (t.isTransfer) toTokens[t.soNum.toUpperCase()] = token;
        }
        return <Order>[...ship, ...transfers]
            .map((o) => o.withCarrierName(name))
            .toList();
      } on UnauthorizedException {
        unauthorized = true;
        failed.add(a.username);
        return <Order>[];
      } catch (_) {
        failed.add(a.username);
        return <Order>[];
      }
    }));

    final merged = <Order>[];
    final seen = <String>{};
    for (final list in lists) {
      for (final o in list) {
        if (seen.add(orderKey(o))) merged.add(o);
      }
    }
    return OrdersLoad(
        orders: merged,
        toTokens: toTokens,
        failedTrucks: failed,
        unauthorized: unauthorized);
  }
}
