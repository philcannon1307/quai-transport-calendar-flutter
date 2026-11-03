import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../state/providers.dart";
import "../theme.dart";

/// Protects /calendar and /my-orders: with no stored session (or after the
/// backend rejected it) the user is sent to the login screen instead of seeing
/// an empty calendar. A valid persisted session passes straight through, so a
/// refresh or a deep link keeps working.
class AuthGuard extends ConsumerStatefulWidget {
  const AuthGuard({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends ConsumerState<AuthGuard> {
  bool _redirected = false;

  void _toLogin() {
    if (_redirected) return;
    _redirected = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil("/", (_) => false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final expired = ref.watch(sessionExpiredProvider);
    final signedIn = ref.watch(sessionProvider).token() != null;
    if (!signedIn || expired) {
      _toLogin();
      return const Scaffold(backgroundColor: kNavy, body: SizedBox.shrink());
    }
    return widget.child;
  }
}
