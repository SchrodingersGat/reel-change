import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";

import "package:inventree_smt/auth/session_store.dart";
import "package:inventree_smt/inventree/models.dart";

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

class SettingsStore extends ChangeNotifier {
  SettingsStore(this._backend);

  final SettingsBackend _backend;

  WorkflowSettings _settings = const WorkflowSettings();
  WorkflowSettings get settings => _settings;

  String _origin = "";

  /// Load the settings stored for [server] (settings for another server are ignored).
  Future<void> load(String server) async {
    _origin = serverOrigin(server);
    _settings = const WorkflowSettings();

    try {
      final String? raw = await _backend.read();
      if (raw != null) {
        final Map<String, dynamic> data =
            json.decode(raw) as Map<String, dynamic>;

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
    }

    notifyListeners();
  }

  Future<void> save(WorkflowSettings settings) async {
    _settings = settings;
    notifyListeners();

    await _backend.write(
      json.encode({
        "origin": _origin,
        if (settings.source != null) "source": settings.source!.toJson(),
        if (settings.machine != null) "machine": settings.machine!.toJson(),
      }),
    );
  }
}
