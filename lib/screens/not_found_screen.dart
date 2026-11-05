import "package:flutter/material.dart";

import "../i18n/i18n.dart";
import "../widgets/bilingual.dart";

/// Any route the app does not know (reference: pages/NotFound.tsx).
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F6),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text("404",
                key: Key("not-found-code"),
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(bi(s, "Oups ! Page introuvable", "Oops! Page not found"),
                style: const TextStyle(fontSize: 20, color: Colors.black54)),
            const SizedBox(height: 12),
            TextButton(
              key: const Key("not-found-home"),
              onPressed: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil("/", (_) => false),
              child: Text(bi(s, "Retour à l'accueil", "Return to Home")),
            ),
          ],
        ),
      ),
    );
  }
}
