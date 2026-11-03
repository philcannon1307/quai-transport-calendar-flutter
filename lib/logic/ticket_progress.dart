import "dart:math" as math;

/// Which stage the picking-ticket load is in.
enum TicketPhase { server, download, render }

const double kStartProgress = 3;
const double kRenderProgress = 92;
const double kDoneProgress = 100;

/// NetSuite gives no progress while it builds the PDF, so the bar eases toward
/// 70% over ~8 s and never goes backwards. Ported from PickingTicketSheet.tsx.
double nextServerProgress(double current, int elapsedMs) {
  if (current >= 70) return current;
  return math.max(current, 70 * (1 - math.exp(-elapsedMs / 4000)));
}

/// Download stage maps 0..1 onto 70..90; an unknown length parks at 80.
/// Never moves the bar backwards.
double downloadProgress(double current, double? fraction) {
  final target = fraction == null ? 80.0 : 70 + fraction * 20;
  return math.max(current, target);
}
