import "package:flutter/services.dart";

import "package:reel_change/core/app_log.dart";

/// Small native bridge (see android/.../MainActivity.kt):
/// - keep the screen on (FLAG_KEEP_SCREEN_ON on the activity window)
/// - app version information
/// - Zebra DataWedge scans (broadcast intents forwarded on an event channel)
///
/// Calls fail quietly (and are logged) where the native side is missing,
/// e.g. in widget tests.
class DeviceService {
  const DeviceService();

  static const MethodChannel _channel = MethodChannel(
    "org.inventree.reel_change/device",
  );

  static const EventChannel _scans = EventChannel(
    "org.inventree.reel_change/scans",
  );

  /// Barcodes scanned with the device's hardware scanner (DataWedge).
  /// The native receiver is only registered while this stream has listeners
  /// and the app is in the foreground.
  Stream<String> get hardwareScans => _sharedScans;

  // One native subscription shared by all listeners (a second
  // receiveBroadcastStream() would replace the first on the native side)
  static final Stream<String> _sharedScans = _scans
      .receiveBroadcastStream()
      .where((e) => e is String)
      .cast<String>()
      .handleError((Object e) {
        if (e is! MissingPluginException) {
          appLog.warning("scanner", "DataWedge scan stream error: $e");
        }
      });

  /// True if Zebra DataWedge is installed on this device.
  Future<bool> dataWedgeInstalled() async {
    try {
      return await _channel.invokeMethod<bool>("dataWedgeInstalled") ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      appLog.warning("scanner", "Could not check for DataWedge: ${e.message}");
      return false;
    }
  }

  /// Create the DataWedge profile for this app (if it does not already
  /// exist). Returns false if DataWedge is not installed or the request
  /// could not be sent.
  Future<bool> configureDataWedge() async {
    try {
      final bool ok =
          await _channel.invokeMethod<bool>("configureDataWedge") ?? false;
      appLog.info(
        "scanner",
        ok
            ? "DataWedge profile \"Reel Change\" requested"
            : "DataWedge is not installed",
      );
      return ok;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      appLog.warning("scanner", "Could not configure DataWedge: ${e.message}");
      return false;
    }
  }

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
