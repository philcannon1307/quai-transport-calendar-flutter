import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:intl/intl.dart";

import "../api/auth_service.dart";
import "../api/session.dart";
import "../i18n/i18n.dart";
import "../logic/admin_filters.dart";
import "../logic/order_windows.dart";
import "../models/order.dart";
import "../state/providers.dart";
import "../theme.dart";
import "../widgets/announcement_banner.dart";
import "../widgets/bilingual.dart";
import "ticket_sheet.dart";

/// /admin — SuperUser only. The credentials are checked by the SERVER; the
/// client never holds a password or a carrier login.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});
  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login(Strings s) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(authServiceProvider).signInSuperUser(username: _user.text.trim(), password: _pass.text);
      ref.read(sessionProvider).signIn(token: kSuperToken, name: kSuperUserName, linkedTokens: res.linkedTokens);
      ref.read(currentCarrierProvider.notifier).state = kSuperUserName;
      ref.invalidate(adminLoadProvider);
    } on AuthFailure catch (e) {
      _error = e.message.startsWith("PENDING_BACKEND") || e.message.startsWith("NOT_CONFIGURED")
          ? bi(s, "Connexion administrateur indisponible : le service d'authentification n'est pas encore déployé.",
              "Administrator sign-in unavailable: the authentication service is not deployed yet.")
          : s.t("admin.errorBad");
    } catch (_) {
      _error = s.t("admin.errorNetwork");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final isSuper = ref.watch(sessionProvider).isSuperUser && ref.watch(currentCarrierProvider) == kSuperUserName;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t("admin.title")),
        actions: <Widget>[
          if (isSuper)
            IconButton(
              key: const Key("admin-logout"),
              tooltip: s.t("common.logout"),
              icon: const Icon(Icons.logout),
              onPressed: () {
                signOutNow(ref);
                Navigator.of(context).pushNamedAndRemoveUntil("/", (_) => false);
              },
            ),
        ],
      ),
      body: isSuper ? const _AdminBody() : _form(s),
    );
  }

  Widget _form(Strings s) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(s.t("admin.subtitle"), style: const TextStyle(color: Colors.black54, fontSize: 13)),
                const SizedBox(height: 16),
                TextField(
                  key: const Key("admin-user"),
                  controller: _user,
                  decoration: InputDecoration(labelText: s.t("admin.username"), border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key("admin-pass"),
                  controller: _pass,
                  obscureText: true,
                  decoration: InputDecoration(labelText: s.t("admin.password"), border: const OutlineInputBorder()),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(_error!, key: const Key("admin-error"), style: const TextStyle(color: Color(0xFF9B1C1C), fontSize: 13)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key("admin-submit"),
                  onPressed: _busy ? null : () => _login(s),
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(_busy ? s.t("admin.aggregating") : s.t("admin.submit"))),
                ),
              ],
            ),
          ),
        ),
      );
}

class _AdminBody extends ConsumerWidget {
  const _AdminBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final load = ref.watch(adminLoadProvider);
    final group = ref.watch(adminGroupProvider);
    final locId = ref.watch(adminLocationProvider);
    return load.when(
      loading: () => Center(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        const CircularProgressIndicator(),
        const SizedBox(height: 10),
        Text(s.t("admin.aggregating")),
      ])),
      error: (e, _) => Center(child: Text(s.t("admin.errorNetwork"))),
      data: (data) {
        if (data.orders.isEmpty && data.failedTrucks.isNotEmpty) {
          return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(s.t("admin.errorNone"))));
        }
        final all = data.orders;
        // Group first, then locations are counted within that group so the pills stay consistent.
        final byGroup = filterByGroup(all, group);
        final shown = filterByLocation(byGroup, locId);
        final gCounts = groupCounts(all);
        final lCounts = locationCounts(byGroup);
        final groups = visibleSorted<String>(allGroups(), (g) => gCounts[g] ?? 0, (g) => g == group);
        final locs = visibleSorted<LocationRef>(locationsOf(byGroup), (l) => lCounts[l.id] ?? 0, (l) => l.id == locId);
        final fmt = DateFormat.MMMEd(s.isFrench ? "fr_CA" : "en_CA");
        final sorted = [...shown]..sort((a, b) => a.date.compareTo(b.date));
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: <Widget>[
            const AnnouncementBanner(),
            const SizedBox(height: 10),
            if (data.failedTrucks.isNotEmpty)
              Text("${bi(s, "Non chargés", "Not loaded")}: ${data.failedTrucks.join(", ")}",
                  style: const TextStyle(color: Color(0xFF92400E), fontSize: 12)),
            Text(s.t("dash.group"), style: const TextStyle(fontWeight: FontWeight.w600)),
            Wrap(spacing: 6, children: <Widget>[
              for (final g in groups)
                ChoiceChip(
                  key: Key("group-$g"),
                  label: Text("$g (${gCounts[g] ?? 0})"),
                  selected: g == group,
                  onSelected: (on) {
                    ref.read(adminGroupProvider.notifier).state = on ? g : null;
                    ref.read(adminLocationProvider.notifier).state = null;
                  },
                ),
            ]),
            const SizedBox(height: 8),
            Text(s.t("dash.locations"), style: const TextStyle(fontWeight: FontWeight.w600)),
            Wrap(spacing: 6, children: <Widget>[
              for (final l in locs)
                ChoiceChip(
                  key: Key("loc-${l.id}"),
                  label: Text("${l.name} (${lCounts[l.id] ?? 0})"),
                  selected: l.id == locId,
                  onSelected: (on) => ref.read(adminLocationProvider.notifier).state = on ? l.id : null,
                ),
            ]),
            if (group != null || locId != null)
              TextButton(
                key: const Key("admin-clear"),
                onPressed: () {
                  ref.read(adminGroupProvider.notifier).state = null;
                  ref.read(adminLocationProvider.notifier).state = null;
                },
                child: Text(s.t("dash.clearFilters")),
              ),
            const SizedBox(height: 8),
            Text("${sorted.length} ${s.t("dash.orders")}", key: const Key("admin-count"), style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final o in sorted)
              Card(
                key: Key("admin-order-${o.soNum}"),
                margin: const EdgeInsets.only(top: 8),
                child: ListTile(
                  title: Text(o.soNum, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([o.customer, o.serviceType, o.carrierName].where((e) => (e ?? "").isNotEmpty).join(" · ")),
                  trailing: Text(OrderWindows.parseDate(o.date) == null ? "" : fmt.format(OrderWindows.parseDate(o.date)!),
                      style: const TextStyle(fontSize: 12, color: kPurple)),
                  onTap: () => showTicketSheet(context, o.soNum),
                ),
              ),
          ],
        );
      },
    );
  }
}

// Order is referenced so the analyzer keeps the model import used by callers' tests.
typedef AdminOrder = Order;
