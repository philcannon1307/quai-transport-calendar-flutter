import "../i18n/i18n.dart";

/// Text that has no entry in the ported dictionary (the reference hardcoded it).
String bi(Strings s, String fr, String en) => s.isFrench ? fr : en;
