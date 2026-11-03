import "dart:typed_data";

import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// Builds the in-app PDF view. The real one (pdfrx) is injected from main.dart;
/// keeping the engine out of this file means widget tests never load a PDF engine.
typedef TicketPdfBuilder = Widget Function(BuildContext context, Uint8List bytes, String name);

/// Print and download of a ticket. The real one (printing) is injected from main.dart.
abstract class TicketFileActions {
  Future<void> printPdf(Uint8List bytes, String name);
  Future<void> download(Uint8List bytes, String name);
}

class NoopTicketFileActions implements TicketFileActions {
  const NoopTicketFileActions();
  @override
  Future<void> printPdf(Uint8List bytes, String name) async {}
  @override
  Future<void> download(Uint8List bytes, String name) async {}
}

final ticketPdfBuilderProvider = Provider<TicketPdfBuilder>(
  (ref) => (context, bytes, name) => const Center(child: Text("PDF viewer unavailable")),
);

final ticketFileActionsProvider = Provider<TicketFileActions>((ref) => const NoopTicketFileActions());
