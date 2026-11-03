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
    // Never null and never a loading state: the dictionary is preloaded in
    // main(), and while a locale switch is in flight we keep showing the
    // previous one. This guarantees exactly ONE MaterialApp for the app's
    // lifetime, so the Navigator keeps the route the URL asked for.
    final asyncStrings = ref.watch(stringsProvider);
    final Strings strings =
        asyncStrings.hasValue ? asyncStrings.requireValue : ref.watch(preloadedStringsProvider);

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
        routes: <String, WidgetBuilder>{
          "/": (_) => const LoginScreen(),
          "/calendar": (_) => const CalendarScreen(),
          "/my-orders": (_) => const MyOrdersScreen(),
        },
      ),
    );
  }
}
