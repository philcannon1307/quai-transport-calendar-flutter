import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:intl/date_symbol_data_local.dart";

import "app.dart";
import "i18n/i18n.dart";
import "pdf/pdf_ports.dart";
import "pdf/pdfrx_impl.dart";
import "platform/image_picker_impl.dart";
import "platform/photo_picker.dart";
import "state/providers.dart";

Future<void> main() async {
  // URL STRATEGY: keep Flutter's DEFAULT hash strategy (/#/calendar).
  // usePathUrlStrategy() was tried and reverted: this Firebase Hosting site has
  // no SPA rewrite, so /calendar returns the hosting 404 and the app never
  // boots (verified on v8). Clean paths need a hosting rewrite to index.html.
  WidgetsFlutterBinding.ensureInitialized();
  initializeDateFormatting();
  // pdfrxFlutterInitialize() is deliberately NOT called: it does not exist in the
  // pdfrx 1.x release pub resolves here (analyze: undefined_function). 1.x sets up
  // its document factory itself. PdfrxTextExtractor swallows any failure, so a
  // problem there would show as "no Call/Directions buttons", not a crash.

  // Load the dictionary BEFORE runApp. Previously app.dart rendered a loading
  // MaterialApp while this future resolved and then built a SECOND MaterialApp,
  // which reset the Navigator to "/" and silently broke every deep link and
  // page refresh (/#/calendar always landed on the login screen). One
  // MaterialApp must mount once, with the URL route intact.
  final strings = await Strings.load(const Locale("fr"));

  runApp(ProviderScope(
    overrides: <Override>[
      preloadedStringsProvider.overrideWithValue(strings),
      // The PDF engine and print support are injected here so nothing else (and
      // no test) imports them.
      pdfTextExtractorProvider.overrideWithValue(const PdfrxTextExtractor()),
      ticketPdfBuilderProvider.overrideWithValue(pdfrxTicketBuilder),
      ticketFileActionsProvider.overrideWithValue(const PrintingFileActions()),
      photoPickerProvider.overrideWithValue(ImagePickerPhotoPicker()),
    ],
    child: const QuaiApp(),
  ));
}
