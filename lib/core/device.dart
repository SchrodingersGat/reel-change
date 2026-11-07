import "package:flutter/services.dart";

import "package:reel_change/core/app_log.dart";

/// Small native bridge (see android/.../MainActivity.kt):
/// - keep the screen on (FLAG_KEEP_SCREEN_ON on the activity window)
/// - app version information
///
/// Calls fail quietly (and are logged) where the native side is missing,
/// e.g. in widget tests.
class DeviceService {
  const DeviceService();

  static const MethodChannel _channel = MethodChannel(
    "org.inventree.reel_change/device",
  );

  Future<void> setKeepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<void>("setKeepScreenOn", on);
      appLog.debug("device", "Keep screen on: $on");
    } on MissingPluginException {
      // Not running on Android (tests)
    } on PlatformException catch (e) {
      appLog.warning("device", "Could not set keep-screen-on: ${e.message}");
    }
  }

  /// e.g. "1.0.0 (1)", or "" if unavailable.
  Future<String> appVersion() async {
    try {
      final Map<Object?, Object?>? info = await _channel
          .invokeMapMethod<Object?, Object?>("appInfo");
      if (info == null) return "";
      return "${info["versionName"]} (${info["versionCode"]})";
    } on MissingPluginException {
      return "";
    } on PlatformException catch (e) {
      appLog.warning("device", "Could not read app version: ${e.message}");
      return "";
    }
  }
}
