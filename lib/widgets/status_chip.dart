import "package:flutter/material.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_week.dart";
import "../theme/quai_tokens.dart";

/// Status chip. Shape cue first, colour second: filled dot = confirmed, HOLLOW dot = provisional
/// (`hollow`), filled dot + struck-through name on the card = cancelled. Never brand orange.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.label, this.hollow});
  final QuaiStatus status;

  /// Overrides the localized label.
  final String? label;

  /// Hollow dot; defaults to true for provisional.
  final bool? hollow;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    final (Color fg, Color bg, String key) = switch (status) {
      QuaiStatus.confirmed => (c.confirmed, c.confirmedBg, "status.confirmed"),
      QuaiStatus.tentative => (c.tentative, c.tentativeBg, "status.tentative"),
      QuaiStatus.cancelled => (c.cancelled, c.cancelledBg, "status.cancelled"),
    };
    final isHollow = hollow ?? status == QuaiStatus.tentative;
    return Container(
      key: Key("status-${status.name}"),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(QuaiRadius.full)),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Container(
          key: Key(isHollow ? "dot-hollow" : "dot-filled"),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isHollow ? Colors.transparent : fg,
            border: isHollow ? Border.all(color: fg, width: 1.5) : null,
          ),
        ),
        const SizedBox(width: 5),
        Text((label ?? s.t(key)).toUpperCase(),
            style: quaiSans(fg,
                size: 10, height: 12, weight: FontWeight.w700, ls: .4)),
      ]),
    );
  }
}
