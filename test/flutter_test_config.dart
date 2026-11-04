import "dart:async";

import "package:quai_calendar/theme/quai_tokens.dart";

/// Runs before every test file: no runtime font downloads in tests.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  QuaiFonts.enabled = false;
  await testMain();
}
