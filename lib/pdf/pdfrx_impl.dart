import "dart:typed_data";

import "package:flutter/material.dart";
import "package:pdfrx/pdfrx.dart";
import "package:printing/printing.dart";

import "../api/contact_service.dart";
import "../logic/contact_parser.dart";
import "pdf_ports.dart";

/// The ONLY file that imports the PDF engine and the print package. main.dart
/// injects these through providers; the rest of the app and every test stay
/// engine-free.

/// Reads the first page's text with pdfrx (PDFium).
class PdfrxTextExtractor implements PdfTextExtractor {
  const PdfrxTextExtractor();

  @override
  Future<List<String>?> firstPageLines(List<int> pdfBytes) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(Uint8List.fromList(pdfBytes));
      if (doc.pages.isEmpty) return null;
      final dynamic text = await doc.pages.first.loadText();
      final full = text?.fullText as String?;
      if (full == null) return null;
      return linesFromPdfText(full);
    } catch (_) {
      return null;
    } finally {
      await doc?.dispose();
    }
  }
}

/// Scrollable, zoomable multi-page view.
Widget pdfrxTicketBuilder(BuildContext context, Uint8List bytes, String name) {
  return ColoredBox(
    color: const Color(0xFFEDEBF3),
    child: PdfViewer.data(bytes, sourceName: "ticket-$name"),
  );
}

/// Browser print dialog and file download.
class PrintingFileActions implements TicketFileActions {
  const PrintingFileActions();

  @override
  Future<void> printPdf(Uint8List bytes, String name) async {
    await Printing.layoutPdf(name: name, onLayout: (_) async => bytes);
  }

  @override
  Future<void> download(Uint8List bytes, String name) async {
    await Printing.sharePdf(bytes: bytes, filename: "$name.pdf");
  }
}
