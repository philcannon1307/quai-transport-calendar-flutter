import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:intl/date_symbol_data_local.dart";

import "app.dart";

void main() {
  // URL STRATEGY: keep Flutter's DEFAULT hash strategy (/#/calendar).
  // usePathUrlStrategy() was tried and reverted: this Firebase Hosting site has
  // no SPA rewrite, so a deep path like /calendar returns the hosting 404
  // ("Page Not Found") instead of index.html — verified on v8. Hash routes need
  // no rewrite and survive a refresh. Revisit only alongside a hosting rewrite.
  initializeDateFormatting();
  runApp(const ProviderScope(child: QuaiApp()));
}
