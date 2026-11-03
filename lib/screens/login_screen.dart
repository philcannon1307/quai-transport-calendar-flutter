import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/carriers.dart";
import "../i18n/i18n.dart";
import "../models/carrier.dart";
import "../state/providers.dart";
import "../theme.dart";
import "../widgets/bilingual.dart";

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  String? _carrier;
  final TextEditingController _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit(Strings s) async {
    final name = _carrier;
    if (name == null) {
      return; // button is disabled until a unit is chosen

    }
    if (_code.text.trim().length != 6) {
      return; // button is disabled until the 6-digit code is complete
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Carrier? carrier = carrierByDisplayName(name);
      if (carrier == null) throw Exception("unknown carrier");
      final res = await ref.read(authServiceProvider).signIn(carrier: carrier, code: _code.text.trim());
      ref.read(sessionProvider).signIn(
        token: res.primaryToken,
        name: name,
        linkedTokens: res.linkedTokens,
        role: res.role,
        sessionToken: res.sessionToken,
      );
      ref.read(sessionExpiredProvider.notifier).state = false;
      ref.read(currentCarrierProvider.notifier).state = name;
      if (mounted) Navigator.of(context).pushReplacementNamed("/calendar");
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final groups = carriersByGroup();
    final items = <DropdownMenuItem<String>>[];
    groups.forEach((group, list) {
      items.add(DropdownMenuItem<String>(
        enabled: false,
        value: "__group_$group",
        child: Text(group, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black54)),
      ));
      for (final c in list) {
        items.add(DropdownMenuItem<String>(value: c.displayName, child: Text(c.displayName)));
      }
    });

    return Scaffold(
      backgroundColor: kNavy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[_LangToggle()],
                  ),
                  const SizedBox(height: 8),
                  Text(s.t("brand.name"),
                      style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
                  Text(s.t("brand.tagline"), style: const TextStyle(color: Colors.white70, fontSize: 15)),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(s.t("login.title"), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(s.t("login.subtitle"), style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        const SizedBox(height: 18),
                        if (ref.watch(sessionExpiredProvider)) ...<Widget>[
                          Container(
                            key: const Key("session-expired"),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(8)),
                            child: Text(
                              bi(s, "Session expirée — reconnectez-vous.", "Session expired — sign in again."),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        InputDecorator(
                          decoration: InputDecoration(
                            labelText: s.t("login.unit"),
                            border: const OutlineInputBorder(),
                          ),
                          isEmpty: _carrier == null,
                          child: DropdownButton<String>(
                            value: _carrier,
                            isExpanded: true,
                            underline: const SizedBox.shrink(),
                            items: items,
                            onChanged: (v) {
                              if (v == null || v.startsWith("__group_")) return;
                              setState(() => _carrier = v);
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _code,
                          onChanged: (_) => setState(() {}),
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 6,
                          decoration: InputDecoration(
                            labelText: s.t("login.password"),
                            border: const OutlineInputBorder(),
                            counterText: "",
                          ),
                        ),
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFDECEC),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFF5C2C2)),
                            ),
                            child: Text(_error!, style: const TextStyle(color: Color(0xFF9B1C1C), fontSize: 12)),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: (_busy || _carrier == null || _code.text.trim().length != 6) ? null : () => _submit(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(_busy ? s.t("login.submitting") : s.t("login.submit")),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    key: const Key("login-admin-link"),
                    onPressed: () => Navigator.of(context).pushNamed("/admin"),
                    child: Text(s.t("login.admin"), style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Alias kept local so the screen does not import session key names directly.
const String kTokenKeyAlias = "quai_contractor_token";

class _LangToggle extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final isFr = locale.languageCode != "en";
    return Row(
      children: <Widget>[
        _chip("FR", isFr, () => ref.read(localeProvider.notifier).state = const Locale("fr")),
        const SizedBox(width: 6),
        _chip("EN", !isFr, () => ref.read(localeProvider.notifier).state = const Locale("en")),
      ],
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? kPurple : Colors.white24,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      );
}
