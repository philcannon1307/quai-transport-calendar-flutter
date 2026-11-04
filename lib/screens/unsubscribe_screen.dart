import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/backend_gateway.dart";
import "../i18n/i18n.dart";
import "../state/providers.dart";
import "../theme.dart";
import "../widgets/bilingual.dart";

/// /unsubscribe?token=... — public page opened from the footer link of every email.
class UnsubscribeScreen extends ConsumerStatefulWidget {
  const UnsubscribeScreen({super.key, required this.token});
  final String? token;
  @override
  ConsumerState<UnsubscribeScreen> createState() => _UnsubscribeScreenState();
}

enum _Phase { checking, ready, working, done, already, invalid, error }

class _UnsubscribeScreenState extends ConsumerState<UnsubscribeScreen> {
  _Phase _phase = _Phase.checking;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final r = await ref.read(unsubscribeServiceProvider).check(widget.token);
    if (!mounted) return;
    setState(() {
      _phase = switch (r) {
        UnsubscribeCheck.valid => _Phase.ready,
        UnsubscribeCheck.alreadyUnsubscribed => _Phase.already,
        UnsubscribeCheck.invalid => _Phase.invalid,
      };
    });
  }

  Future<void> _confirm() async {
    setState(() => _phase = _Phase.working);
    final r = await ref.read(unsubscribeServiceProvider).confirm(widget.token!);
    if (!mounted) return;
    setState(() {
      _phase = switch (r) {
        UnsubscribeResult.done => _Phase.done,
        UnsubscribeResult.alreadyUnsubscribed => _Phase.already,
        UnsubscribeResult.error => _Phase.error,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    String msg;
    switch (_phase) {
      case _Phase.checking:
      case _Phase.working:
        msg = bi(s, "Un instant…", "One moment…");
      case _Phase.ready:
        msg = bi(
            s,
            "Voulez-vous vous désabonner des courriels de Quai Lafantaisie ?",
            "Do you want to unsubscribe from Quai Lafantaisie emails?");
      case _Phase.done:
        msg = bi(s, "Vous êtes désabonné. Vous ne recevrez plus ces courriels.",
            "You are unsubscribed. You will no longer receive these emails.");
      case _Phase.already:
        msg =
            bi(s, "Vous êtes déjà désabonné.", "You are already unsubscribed.");
      case _Phase.invalid:
        msg = bi(s, "Ce lien est invalide ou a expiré.",
            "This link is invalid or has expired.");
      case _Phase.error:
        msg = bi(s, "Une erreur est survenue. Réessayez plus tard.",
            "Something went wrong. Please try again later.");
    }
    final bool waiting = _phase == _Phase.checking || _phase == _Phase.working;
    final IconData icon = switch (_phase) {
      _Phase.done || _Phase.already => Icons.check_circle_outline,
      _Phase.invalid || _Phase.error => Icons.error_outline,
      _ => Icons.mail_outline,
    };
    final Color iconColor = switch (_phase) {
      _Phase.done || _Phase.already => kPurple,
      _Phase.invalid || _Phase.error => const Color(0xFFD64545),
      _ => kNavy,
    };
    // Reference (pages/Unsubscribe.tsx): a LIGHT page with a centred bordered card.
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFFFCFCFD),
                border: Border.all(color: const Color(0xFFE2E5EA)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFFF1F3F6),
                    child: Icon(waiting ? Icons.hourglass_empty : icon,
                        color: waiting ? Colors.black45 : iconColor),
                  ),
                  const SizedBox(height: 16),
                  Text(s.t("brand.name"),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Colors.black54)),
                  const SizedBox(height: 8),
                  Text(msg,
                      key: const Key("unsub-message"),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16)),
                  if (_phase == _Phase.ready) ...<Widget>[
                    const SizedBox(height: 18),
                    FilledButton(
                      key: const Key("unsub-confirm"),
                      style: FilledButton.styleFrom(backgroundColor: kNavy),
                      onPressed: _confirm,
                      child: Text(bi(s, "Me désabonner", "Unsubscribe")),
                    ),
                  ],
                  if (_phase == _Phase.error) ...<Widget>[
                    const SizedBox(height: 18),
                    OutlinedButton(
                        key: const Key("unsub-retry"),
                        onPressed: _confirm,
                        child: Text(s.t("common.retry"))),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
