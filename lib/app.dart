import "package:flutter/material.dart";
import "package:flutter_localizations/flutter_localizations.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "i18n/i18n.dart";
import "screens/calendar_screen.dart";
import "screens/login_screen.dart";
import "screens/my_orders_screen.dart";
import "state/providers.dart";
import "theme.dart";
import "api/unsubscribe_service.dart";
import "screens/admin_screen.dart";
import "screens/unsubscribe_screen.dart";
import "screens/not_found_screen.dart";
import "widgets/auth_guard.dart";

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
        // ONE route table (onGenerateRoute) so the URL the browser opened is honoured
        // for known paths and an unknown path shows the NotFound screen instead of
        // silently falling back to another page.
        onGenerateInitialRoutes: (String initial) => <Route<dynamic>>[_routeFor(RouteSettings(name: initial))],
        onGenerateRoute: _routeFor,
        onUnknownRoute: _routeFor,
      ),
    );
  }
}


/// Path of a route name, without query, hash leftovers or a trailing slash.
String routePath(String? name) {
  final raw = (name == null || name.isEmpty) ? "/" : name;
  var path = Uri.tryParse(raw)?.path ?? raw;
  if (path.length > 1 && path.endsWith("/")) path = path.substring(0, path.length - 1);
  return path.isEmpty ? "/" : path;
}

Route<dynamic> _routeFor(RouteSettings settings) {
  final name = settings.name ?? "/";
  final Widget page;
  switch (routePath(name)) {
    case "/":
    case "/login":
      page = const LoginScreen();
    case "/calendar":
      page = const AuthGuard(child: CalendarScreen());
    case "/my-orders":
      page = const AuthGuard(child: MyOrdersScreen());
    case "/admin":
      page = const AdminScreen();
    case "/unsubscribe":
      page = UnsubscribeScreen(token: unsubscribeToken(routeName: name, pageUri: Uri.base));
    default:
      page = const NotFoundScreen();
  }
  return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
}
