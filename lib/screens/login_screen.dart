import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/carriers.dart";
import "../i18n/i18n.dart";
import "../models/carrier.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "../widgets/bilingual.dart";
import "../widgets/brand_header.dart";

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  String? _carrier;
  final TextEditingController _code = TextEditingController();
  final FocusNode _unitFocus = FocusNode();
  String? _error;
  bool _busy = false;
  bool _showCode = false;

  @override
  void dispose() {
    _code.dispose();
    _unitFocus.dispose();
    super.dispose();
  }

  Future<void> _submit(Strings s) async {
    final name = _carrier;
    if (name == null) return; // button is disabled until a unit is chosen
    if (_code.text.trim().length != 6)
      return; // ...and until the 6-digit code is complete
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Carrier? carrier = carrierByDisplayName(name);
      if (carrier == null) throw Exception("unknown carrier");
      final res = await ref
          .read(authServiceProvider)
          .signIn(carrier: carrier, code: _code.text.trim());
      ref.read(sessionProvider).signIn(
            token: res.primaryToken,
            name: name,
            linkedTokens: res.linkedTokens,
            role: res.role,
            sessionToken: res.sessionToken,
          );
      ref.read(sessionExpiredProvider.notifier).state = false;
      ref.read(currentCarrierProvider.notifier).state = name;
      if (mounted) Navigator.of(context).pushReplacementNamed("/calendar");
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickUnit(BuildContext context) async {
    final c = context.q;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(QuaiRadius.sheet))),
      builder: (_) => _UnitSheet(selected: _carrier),
    );
    if (picked != null && mounted) setState(() => _carrier = picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    final width = MediaQuery.of(context).size.width;
    final wide = width >= QuaiBreakpoints.phone;
    final keyboard = MediaQuery.of(context).viewInsets.bottom > 0;
    final ready = !_busy && _carrier != null && _code.text.trim().length == 6;

    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(s.t("login.title"),
            key: const Key("login-title"),
            style:
                quaiSans(c.ink, size: 28, height: 34, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(s.t("login.subtitle"),
            style: quaiSans(c.sub, size: 15, height: 21)),
        const SizedBox(height: 22),
        if (ref.watch(sessionExpiredProvider)) ...<Widget>[
          Container(
            key: const Key("session-expired"),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: c.memoBg,
                borderRadius: BorderRadius.circular(QuaiRadius.sm),
                border: Border(left: BorderSide(color: c.memoRail, width: 4))),
            child: Text(
                bi(s, "Session expirée — reconnectez-vous.",
                    "Session expired — sign in again."),
                style: quaiSans(c.ink, size: 13)),
          ),
          const SizedBox(height: 14),
        ],
        _FieldLabel(s.t("login.unit")),
        const SizedBox(height: 6),
        _UnitField(
            value: _carrier,
            placeholder: s.t("login.unitPlaceholder"),
            onTap: () => _pickUnit(context),
            onSelected: (v) => setState(() => _carrier = v),
            wide: wide),
        const SizedBox(height: 16),
        _FieldLabel(s.t("login.password")),
        const SizedBox(height: 6),
        TextField(
          key: const Key("login-code"),
          controller: _code,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => ready ? _submit(s) : null,
          keyboardType: TextInputType.number,
          obscureText: !_showCode,
          maxLength: 6,
          style: quaiSans(c.ink, size: 16, weight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: s.t("login.passwordPlaceholder"),
            hintStyle: quaiSans(c.faint, size: 15),
            counterText: "",
            constraints: const BoxConstraints(minHeight: 52),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            suffixIcon: IconButton(
              key: const Key("login-eye"),
              tooltip: s.t("login.password"),
              icon: Icon(
                  _showCode
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: c.faint),
              onPressed: () => setState(() => _showCode = !_showCode),
            ),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(QuaiRadius.md),
                borderSide: BorderSide(color: c.primary, width: 2)),
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Container(
            key: const Key("login-error"),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: c.cancelledBg,
                borderRadius: BorderRadius.circular(QuaiRadius.sm)),
            child: Text(_error!,
                style: quaiSans(c.cancelled, size: 12.5, height: 17)),
          ),
        ],
        const SizedBox(height: 22),
        _PrimaryButton(
          key: const Key("login-submit"),
          label: _busy ? s.t("login.submitting") : s.t("login.submit"),
          busy: _busy,
          onPressed: ready ? () => _submit(s) : null,
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            key: const Key("login-admin-link"),
            onPressed: () => Navigator.of(context).pushNamed("/admin"),
            child: Text(s.t("login.admin"),
                style:
                    quaiSans(c.primaryInk, size: 15, weight: FontWeight.w700)),
          ),
        ),
      ],
    );

    final hero = _Hero(
        compact: keyboard && !wide,
        tagline: bi(s, "Calendrier de livraison", "Delivery calendar"));

    if (wide) {
      return Scaffold(
        backgroundColor: c.header,
        body: Stack(children: <Widget>[
          Positioned.fill(child: BrandHeader(child: const SizedBox.expand())),
          Positioned(
              top: 16, right: 24, child: SafeArea(child: const LangToggle())),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child:
                      Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    const BrandLogo(width: 250),
                    const SizedBox(height: 10),
                    Text(bi(s, "Calendrier de livraison", "Delivery calendar"),
                        style: quaiSerif(c.headerSub, size: 16)),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius:
                              BorderRadius.circular(QuaiRadius.sheet - 4),
                          boxShadow: quaiShadow(c, level: 2)),
                      child: form,
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      );
    }

    // Phone: dark brand panel + white sheet that overlaps it by 90 px (sheet top radius 32).
    return Scaffold(
      backgroundColor: c.surface,
      resizeToAvoidBottomInset: true,
      body: Stack(children: <Widget>[
        Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: keyboard ? 160 : 460,
            child: hero),
        Positioned.fill(
          top: keyboard ? 130 : 370,
          child: Container(
            decoration: BoxDecoration(
                color: c.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(32))),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                  child: form),
            ),
          ),
        ),
        Positioned(
            top: 0,
            right: 20,
            child: SafeArea(
                child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: const LangToggle()))),
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.compact, required this.tagline});
  final bool compact;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return BrandHeader(
      stripeAlpha: 0.16 * 0.4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: compact ? 24 : 90),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              const BrandLogo(width: 250),
              const SizedBox(height: 8),
              Text(tagline,
                  key: const Key("login-tagline"),
                  style: quaiSerif(c.headerSub, size: 13)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: quaiSans(context.q.ink,
          size: 13.5, height: 18, weight: FontWeight.w700));
}

/// Unit field: a bottom-sheet list on phone, an inline menu on wide screens.
class _UnitField extends StatelessWidget {
  const _UnitField(
      {required this.value,
      required this.placeholder,
      required this.onTap,
      required this.onSelected,
      required this.wide});
  final String? value;
  final String placeholder;
  final VoidCallback onTap;
  final ValueChanged<String> onSelected;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final field = InkWell(
      key: const Key("login-unit"),
      borderRadius: BorderRadius.circular(QuaiRadius.md),
      onTap: wide ? null : onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
            color: c.field,
            borderRadius: BorderRadius.circular(QuaiRadius.md),
            border: Border.all(color: c.line)),
        child: Row(children: <Widget>[
          Expanded(
            child: Text(value ?? placeholder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: quaiSans(value == null ? c.faint : c.ink,
                    size: 16,
                    weight: value == null ? FontWeight.w500 : FontWeight.w600)),
          ),
          Icon(Icons.arrow_drop_down, color: c.primaryInk),
        ]),
      ),
    );
    if (!wide) return field;
    return MenuAnchor(
      style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(c.surface),
          maximumSize: const WidgetStatePropertyAll<Size>(Size(384, 360))),
      menuChildren: <Widget>[
        SizedBox(
          width: 384,
          height: 340,
          child: _UnitList(
              selected: value,
              onSelected: onSelected,
              closeOnPick: false,
              afterPick: () {}),
        ),
      ],
      builder: (context, controller, _) => InkWell(
        key: const Key("login-unit"),
        borderRadius: BorderRadius.circular(QuaiRadius.md),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: IgnorePointer(child: field),
      ),
    );
  }
}

class _UnitSheet extends StatelessWidget {
  const _UnitSheet({required this.selected});
  final String? selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: _UnitList(
          selected: selected,
          onSelected: (v) => Navigator.of(context).pop(v),
          closeOnPick: true,
          afterPick: () {}),
    );
  }
}

/// Searchable, grouped list of units.
class _UnitList extends StatefulWidget {
  const _UnitList(
      {required this.selected,
      required this.onSelected,
      required this.closeOnPick,
      required this.afterPick});
  final String? selected;
  final ValueChanged<String> onSelected;
  final bool closeOnPick;
  final VoidCallback afterPick;
  @override
  State<_UnitList> createState() => _UnitListState();
}

class _UnitListState extends State<_UnitList> {
  String _q = "";

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final groups = carriersByGroup();
    final q = _q.trim().toLowerCase();
    final children = <Widget>[];
    groups.forEach((group, list) {
      final items = list
          .where((e) =>
              q.isEmpty ||
              e.displayName.toLowerCase().contains(q) ||
              group.toLowerCase().contains(q))
          .toList();
      if (items.isEmpty) return;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Text(group.toUpperCase(),
            style: quaiSans(c.sub,
                size: 10.5, height: 12, weight: FontWeight.w700, ls: .8)),
      ));
      for (final e in items) {
        final sel = e.displayName == widget.selected;
        children.add(ListTile(
          key: Key("unit-${e.displayName}"),
          dense: true,
          title: Text(e.displayName,
              style: quaiSans(c.ink,
                  size: 15.5, weight: sel ? FontWeight.w700 : FontWeight.w500)),
          trailing:
              sel ? Icon(Icons.check, color: c.primaryInk, size: 20) : null,
          tileColor: sel ? c.primarySoft : null,
          onTap: () {
            widget.onSelected(e.displayName);
            if (!widget.closeOnPick) MenuController.maybeOf(context)?.close();
          },
        ));
      }
    });
    return Column(children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: TextField(
          key: const Key("unit-search"),
          onChanged: (v) => setState(() => _q = v),
          style: quaiSans(c.ink, size: 15),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, color: c.faint),
            hintText: "Rechercher / Search",
            hintStyle: quaiSans(c.faint, size: 14),
          ),
        ),
      ),
      Expanded(child: ListView(children: children)),
    ]);
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton(
      {super.key,
      required this.label,
      required this.busy,
      required this.onPressed});
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final enabled = onPressed != null;
    // Disabled keeps the grey fill from the current build; enabled has a 2 px darker under-edge as pressed depth.
    final bg = enabled || busy ? c.primary : c.line;
    final fg = enabled || busy ? c.onPrimary : c.faint;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: bg,
        boxShadow: enabled || busy
            ? <BoxShadow>[
                BoxShadow(
                    color: c.primaryInk.withValues(alpha: .9),
                    offset: const Offset(0, 2))
              ]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: Center(
            child: busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: c.onPrimary))
                : Text(label,
                    style: quaiSans(fg, size: 17, weight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}
