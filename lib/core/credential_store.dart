import "package:flutter_secure_storage/flutter_secure_storage.dart";

/// The server the app is set up for, and the last username used to log in.
/// The password is never stored.
class ServerProfile {
  const ServerProfile({required this.server, this.username = ""});

  final String server;
  final String username;
}

/// Persistent storage for the server profile and the session cookies.
abstract class CredentialStore {
  Future<ServerProfile?> loadProfile();

  Future<void> saveProfile(ServerProfile profile);

  /// Serialized [SessionStore] (see SessionStore.toJson), or null.
  Future<String?> loadSession();

  /// Store the serialized session. A null value removes it.
  Future<void> saveSession(String? data);

  /// Serialized [TrustedCertificate] (see TrustedCertificate.toJson), or null.
  Future<String?> loadTrustedCertificate();

  /// Store the trusted certificate. A null value removes it.
  Future<void> saveTrustedCertificate(String? data);
}

/// Everything is kept in platform secure storage (Android Keystore-backed,
/// AES-GCM). The app has `android:allowBackup="false"`, so nothing is
/// included in device backups or transfers.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const String _keyServer = "server";
  static const String _keyUsername = "username";
  static const String _keySession = "session";
  static const String _keyCertificate = "trusted_certificate";

  @override
  Future<ServerProfile?> loadProfile() async {
    final String? server = await _storage.read(key: _keyServer);

    if (server == null || server.isEmpty) return null;

    final String username = await _storage.read(key: _keyUsername) ?? "";

    return ServerProfile(server: server, username: username);
  }

  @override
  Future<void> saveProfile(ServerProfile profile) async {
    await _storage.write(key: _keyServer, value: profile.server);
    await _storage.write(key: _keyUsername, value: profile.username);
  }

  @override
  Future<String?> loadSession() => _storage.read(key: _keySession);

  @override
  Future<String?> loadTrustedCertificate() =>
      _storage.read(key: _keyCertificate);

  @override
  Future<void> saveTrustedCertificate(String? data) async {
    if (data == null) {
      await _storage.delete(key: _keyCertificate);
    } else {
      await _storage.write(key: _keyCertificate, value: data);
    }
  }

  @override
  Future<void> saveSession(String? data) async {
    if (data == null) {
      await _storage.delete(key: _keySession);
    } else {
      await _storage.write(key: _keySession, value: data);
    }
  }
}

/// In-memory store, for tests.
class MemoryCredentialStore implements CredentialStore {
  ServerProfile? profile;
  String? session;
  String? trustedCertificate;

  @override
  Future<String?> loadTrustedCertificate() async => trustedCertificate;

  @override
  Future<void> saveTrustedCertificate(String? data) async =>
      trustedCertificate = data;

  /// Set to make session writes throw (to test failure handling).
  bool failWrites = false;

  @override
  Future<ServerProfile?> loadProfile() async => profile;

  @override
  Future<void> saveProfile(ServerProfile profile) async {
    this.profile = profile;
  }

  @override
  Future<String?> loadSession() async => session;

  @override
  Future<void> saveSession(String? data) async {
    if (failWrites) throw Exception("write failed");
    session = data;
  }
}
