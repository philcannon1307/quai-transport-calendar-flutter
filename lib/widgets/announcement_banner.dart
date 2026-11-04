import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/announcements_service.dart";
import "../i18n/i18n.dart";
import "../logic/announcements.dart";
import "../platform/photo_picker.dart";
import "../state/providers.dart";
import "../theme.dart";
import "bilingual.dart";

/// Active announcements above the calendar. Everyone reads; only the SuperUser
/// sees the New / Edit / Delete controls.
class AnnouncementBanner extends ConsumerWidget {
  const AnnouncementBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final isSuper = ref.watch(sessionProvider).isSuperUser;
    final list =
        ref.watch(announcementsProvider).valueOrNull ?? const <Announcement>[];
    if (list.isEmpty && !isSuper) return const SizedBox.shrink();
    return Container(
      key: const Key("announcement-banner"),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3EEFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPurple.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.campaign_outlined, size: 18, color: kPurple),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(s.t("announce.title"),
                      style: const TextStyle(fontWeight: FontWeight.w700))),
              if (isSuper)
                TextButton.icon(
                  key: const Key("announce-new"),
                  onPressed: () => showAnnouncementEditor(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(s.t("announce.new")),
                ),
            ],
          ),
          if (list.isEmpty)
            Text(s.t("announce.empty"),
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
          for (final a in list) _Post(a: a, isSuper: isSuper),
        ],
      ),
    );
  }
}

class _Post extends ConsumerWidget {
  const _Post({required this.a, required this.isSuper});
  final Announcement a;
  final bool isSuper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                  child: Text(a.titleFor(french: s.isFrench),
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              if (isSuper) ...<Widget>[
                IconButton(
                  key: Key("announce-edit-${a.id}"),
                  tooltip: s.t("announce.edit"),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => showAnnouncementEditor(context, existing: a),
                ),
                IconButton(
                  key: Key("announce-delete-${a.id}"),
                  tooltip: s.t("announce.delete"),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () async {
                    final ok =
                        await ref.read(announcementsServiceProvider).delete(a);
                    ref.read(announcementsRevisionProvider.notifier).state++;
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? s.t("announce.deleted")
                            : bi(s, "Suppression impossible.",
                                "Could not delete.")),
                      ));
                    }
                  },
                ),
              ],
            ],
          ),
          Text(a.bodyFor(french: s.isFrench),
              style: const TextStyle(fontSize: 13)),
          if (a.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final url in a.images)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(url,
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox(
                              width: 96,
                              height: 96,
                              child: Icon(Icons.broken_image_outlined))),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showAnnouncementEditor(BuildContext context,
    {Announcement? existing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: AnnouncementEditor(existing: existing),
    ),
  );
}

class AnnouncementEditor extends ConsumerStatefulWidget {
  const AnnouncementEditor({super.key, this.existing});
  final Announcement? existing;

  @override
  ConsumerState<AnnouncementEditor> createState() => _AnnouncementEditorState();
}

class _AnnouncementEditorState extends ConsumerState<AnnouncementEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? "");
  late final TextEditingController _body =
      TextEditingController(text: widget.existing?.body ?? "");
  late final TextEditingController _titleFr =
      TextEditingController(text: widget.existing?.titleFr ?? "");
  late final TextEditingController _bodyFr =
      TextEditingController(text: widget.existing?.bodyFr ?? "");
  final List<PickedPhoto> _new = <PickedPhoto>[];
  late final List<String> _kept =
      List<String>.of(widget.existing?.images ?? const <String>[]);
  final List<String> _removed = <String>[];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _titleFr.dispose();
    _bodyFr.dispose();
    super.dispose();
  }

  Future<void> _save(Strings s) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await ref.read(announcementsServiceProvider).save(
          draft: AnnouncementDraft(
              title: _title.text,
              body: _body.text,
              titleFr: _titleFr.text,
              bodyFr: _bodyFr.text),
          existing: widget.existing,
          newPhotos: _new.map((p) => NewPhoto(p.bytes, p.name)).toList(),
          removedUrls: _removed,
        );
    if (!mounted) return;
    if (!res.isOk) {
      setState(() {
        _busy = false;
        _error = res.failure == AnnouncementFailure.invalid
            ? bi(s, "Le titre et le message (anglais) sont obligatoires.",
                "The English title and message are required.")
            : bi(s, "Enregistrement impossible. Réessayez.",
                "Could not save. Please try again.");
      });
      return;
    }
    ref.read(announcementsRevisionProvider.notifier).state++;
    final text = widget.existing == null
        ? s.t("announce.created")
        : s.t("announce.updated");
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.photosFailed > 0
          ? "$text ${bi(s, "${res.photosFailed} photo(s) non envoyée(s).", "${res.photosFailed} photo(s) failed to upload.")}"
          : text),
    ));
    Navigator.of(context).pop();
  }

  Widget _field(String key, TextEditingController c, String label,
          {int lines = 1, int? max}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: Key(key),
          controller: c,
          maxLines: lines,
          maxLength: max,
          decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              counterText: ""),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
                s.t(widget.existing == null
                    ? "announce.newTitle"
                    : "announce.editTitle"),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _field("ann-title-en", _title, s.t("announce.fieldTitleEn"),
                max: AnnouncementDraft.maxTitle),
            _field("ann-body-en", _body, s.t("announce.fieldBodyEn"),
                lines: 3, max: AnnouncementDraft.maxBody),
            _field("ann-title-fr", _titleFr, s.t("announce.fieldTitleFr"),
                max: AnnouncementDraft.maxTitle),
            _field("ann-body-fr", _bodyFr, s.t("announce.fieldBodyFr"),
                lines: 3, max: AnnouncementDraft.maxBody),
            if (_kept.isNotEmpty) ...<Widget>[
              Text(s.t("announce.currentPhotos"),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final u in _kept)
                    InputChip(
                      label: Text(Uri.decodeComponent(u.split("/").last),
                          overflow: TextOverflow.ellipsis),
                      onDeleted: () => setState(() {
                        _kept.remove(u);
                        _removed.add(u);
                      }),
                    ),
                ],
              ),
            ],
            OutlinedButton.icon(
              key: const Key("ann-photos"),
              onPressed: _busy
                  ? null
                  : () async {
                      final ps = await ref.read(photoPickerProvider).pickMany();
                      if (ps.isNotEmpty && mounted)
                        setState(() => _new.addAll(ps));
                    },
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(_new.isEmpty
                  ? s.t("announce.uploadPrompt")
                  : "${_new.length} ${s.t("announce.filesSelected")}"),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_error!,
                  key: const Key("ann-error"),
                  style:
                      const TextStyle(color: Color(0xFF9B1C1C), fontSize: 13)),
            ],
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                      onPressed:
                          _busy ? null : () => Navigator.of(context).pop(),
                      child: Text(s.t("announce.cancel"))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const Key("ann-save"),
                    onPressed: _busy ? null : () => _save(s),
                    child: Text(
                        _busy ? s.t("announce.saving") : s.t("announce.save")),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
