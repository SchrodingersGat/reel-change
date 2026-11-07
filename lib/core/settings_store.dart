import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";

import "package:reel_change/auth/session_store.dart";
import "package:reel_change/inventree/models.dart";

/// Device settings for the reel-loading workflow.
class WorkflowSettings {
  const WorkflowSettings({this.source, this.machine});

  /// Where replacement reels are taken from (including sub-locations).
  final StockLocationInfo? source;

  /// The SMT machine - reels are transferred here.
  final StockLocationInfo? machine;

  bool get isComplete => source != null && machine != null;

  WorkflowSettings copyWith({
    StockLocationInfo? source,
    StockLocationInfo? machine,
  }) => WorkflowSettings(
    source: source ?? this.source,
    machine: machine ?? this.machine,
  );
}

/// Returns a problem with the location choice, or null if it is valid.
String? validateLocations(
  StockLocationInfo? source,
  StockLocationInfo? machine,
) {
  if (machine != null && machine.structural) {
    return "The machine location is structural - stock cannot be placed in it. Choose a different location.";
  }

  if (source != null && machine != null) {
    if (source.pk == machine.pk) {
      return "The source and machine locations must be different.";
    }
    if (source.contains(machine)) {
      return "The machine location must not be inside the source location.";
    }
  }

  return null;
}

/// Persists [WorkflowSettings]. Settings are bound to the server origin, so
/// location IDs from one server are never used against another.
abstract class SettingsBackend {
  Future<String?> read();
  Future<void> write(String? data);
}

class SecureSettingsBackend implements SettingsBackend {
  SecureSettingsBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _key = "workflow_settings";

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String? data) => data == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: data);
}

class MemorySettingsBackend implements SettingsBackend {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String? data) async => this.data = data;
}

/// App behaviour preferences (the same for any server).
class AppPreferences {
  const AppPreferences({this.autoReturn = true, this.keepScreenOn = true});

  factory AppPreferences.fromJson(Map<String, dynamic> json) => AppPreferences(
    autoReturn: json["autoReturn"] != false,
    keepScreenOn: json["keepScreenOn"] != false,
  );

  /// After a transfer, return to step 1 automatically after [autoReturnSeconds].
  final bool autoReturn;

  /// Keep the screen on while a reel swap is in progress.
  final bool keepScreenOn;

  static const int autoReturnSeconds = 5;

  AppPreferences copyWith({bool? autoReturn, bool? keepScreenOn}) =>
      AppPreferences(
        autoReturn: autoReturn ?? this.autoReturn,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      );

  Map<String, dynamic> toJson() => {
    "autoReturn": autoReturn,
    "keepScreenOn": keepScreenOn,
  };
}

class SettingsStore extends ChangeNotifier {
  SettingsStore(this._backend);

  final SettingsBackend _backend;

  WorkflowSettings _settings = const WorkflowSettings();

  /// Locations - for the current server only.
  WorkflowSettings get settings => _settings;

  AppPreferences _prefs = const AppPreferences();
  AppPreferences get prefs => _prefs;

  String _origin = "";

  /// Load the settings. Locations stored for a different server are ignored.
  Future<void> load(String server) async {
    _origin = serverOrigin(server);
    _settings = const WorkflowSettings();
    _prefs = const AppPreferences();

    try {
      final String? raw = await _backend.read();
      if (raw != null) {
        final Map<String, dynamic> data =
            json.decode(raw) as Map<String, dynamic>;

        if (data["prefs"] is Map<String, dynamic>) {
          _prefs = AppPreferences.fromJson(
            data["prefs"] as Map<String, dynamic>,
          );
        }

        if (data["origin"] == _origin) {
          StockLocationInfo? loc(String key) =>
              data[key] is Map<String, dynamic>
              ? StockLocationInfo.fromJson(data[key] as Map<String, dynamic>)
              : null;
          _settings = WorkflowSettings(
            source: loc("source"),
            machine: loc("machine"),
          );
        }
      }
    } catch (_) {
      _settings = const WorkflowSettings();
      _prefs = const AppPreferences();
    }

    notifyListeners();
  }

  Future<void> _write() => _backend.write(
    json.encode({
      "origin": _origin,
      "prefs": _prefs.toJson(),
      if (_settings.source != null) "source": _settings.source!.toJson(),
      if (_settings.machine != null) "machine": _settings.machine!.toJson(),
    }),
  );

  /// Save the locations.
  Future<void> save(WorkflowSettings settings) async {
    _settings = settings;
    notifyListeners();
    await _write();
  }

  Future<void> savePrefs(AppPreferences prefs) async {
    _prefs = prefs;
    notifyListeners();
    await _write();
  }
}
