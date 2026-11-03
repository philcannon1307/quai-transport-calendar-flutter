import "package:flutter/material.dart";
import "package:flutter_localizations/flutter_localizations.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "i18n/i18n.dart";
import "screens/calendar_screen.dart";
import "screens/login_screen.dart";
import "screens/my_orders_screen.dart";
import "state/providers.dart";
import "theme.dart";

class QuaiApp extends ConsumerWidget {
  const QuaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    return FutureBuilder<Strings>(
      future: ref.watch(stringsProvider.future),
      builder: (context, snap) {
        final strings = snap.data;
        if (strings == null) {
          return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
        }
        return StringsScope(
          strings: strings,
          child: MaterialApp(
            title: "Quai Lafantaisie",
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            locale: locale,
            supportedLocales: Strings.supported,
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // No initialRoute: Flutter Web then honours the browser URL, which
            // makes /#/calendar reachable for review and deep links later.
            routes: <String, WidgetBuilder>{
              "/": (_) => const LoginScreen(),
              "/calendar": (_) => const CalendarScreen(),
              "/my-orders": (_) => const MyOrdersScreen(),
            },
          ),
        );
      },
    );
  }
}
