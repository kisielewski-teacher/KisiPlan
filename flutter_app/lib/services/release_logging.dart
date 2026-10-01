import 'package:flutter/foundation.dart';

/// In release builds `debugPrint` still writes to logcat, and the login code
/// logs fragments of server responses. Silence it there so nothing from the
/// user's session ends up in the device log. Must be called once per isolate
/// (the WorkManager background isolate has its own).
void silenceDebugLogsInRelease() {
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
}
