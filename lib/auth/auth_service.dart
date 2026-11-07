// Login flow adapted from the official InvenTree mobile app (inventree-app),
// lib/auth/auth_manager.dart and the connection logic in lib/api.dart, at commit 085dad4.
// Changes: single server profile; exposes state for the UI as a ChangeNotifier.
//
// MIT License - Copyright (c) 2019 InvenTree. See THIRD_PARTY_NOTICES.md.

import "package:flutter/foundation.dart";

import "package:reel_change/auth/allauth_client.dart";
import "package:reel_change/auth/auth_result.dart";
import "package:reel_change/auth/session_store.dart";
import "package:reel_change/core/api_client.dart";
import "package:reel_change/core/app_log.dart";
import "package:reel_change/core/certificates.dart";
import "package:reel_change/core/credential_store.dart";

enum AuthPhase {
  /// Checking for a stored session on launch (or retrying a connection).
  starting,

  /// Not logged in - show the login screen.
  loggedOut,

  /// Password accepted, waiting for an MFA code.
  mfaRequired,

  /// Logged in, and the session has been verified with the server.
  connected,
}

/// The user's InvenTree roles (from `user/me/roles/`).
class UserRoles {
  const UserRoles({this.roles = const {}, this.superuser = false});

  factory UserRoles.fromJson(Map<String, dynamic> json) {
    final Map<String, Set<String>> roles = {};
    final dynamic r = json["roles"];
    if (r is Map) {
      r.forEach((key, value) {
        roles[key.toString()] = value is List
            ? value.map((v) => v.toString()).toSet()
            : <String>{};
      });
    }
    return UserRoles(roles: roles, superuser: json["is_superuser"] == true);
  }

  final Map<String, Set<String>> roles;
  final bool superuser;

  bool can(String role, String permission) =>
      superuser || (roles[role]?.contains(permission) ?? false);

  /// Permissions the reel-loading workflow needs: role, permission, why.
  static const List<(String, String, String)> required = [
    ("part", "view", "Parts - view (look up parts and MPNs)"),
    ("stock", "view", "Stock - view (list reels)"),
    ("stock", "change", "Stock - change (move reels into the machine)"),
    ("stock_location", "view", "Stock locations - view (choose locations)"),
  ];

  /// Descriptions of required permissions the user does not have.
  List<String> get missing => [
    for (final (role, perm, label) in required)
      if (!can(role, perm)) label,
  ];
}

/// Details of the verified connection, for display.
class ConnectionInfo {
  const ConnectionInfo({
    required this.server,
    required this.username,
    this.fullName = "",
    this.serverVersion = "",
    this.instanceName = "",
    this.apiVersion = 0,
    this.roles = const UserRoles(),
  });

  /// The user's permissions on the server.
  final UserRoles roles;

  final String server;
  final String username;
  final String fullName;
  final String serverVersion;
  final String instanceName;
  final int apiVersion;

  /// Host (and non-default port) of the server, e.g. "localhost:8000".
  String get serverLabel {
    final Uri? uri = Uri.tryParse(server);
    if (uri == null) return server;
    final String path = uri.path == "/" ? "" : uri.path;
    return "${uri.hasPort ? "${uri.host}:${uri.port}" : uri.host}$path";
  }
}

/// Coordinates authentication against the InvenTree server:
/// - on launch, restores the stored session and verifies it with the server
/// - logs in with username / password (plus MFA if required)
/// - persists session cookies (never the password) in secure storage
/// - logs out
class AuthService extends ChangeNotifier {
  AuthService({required CredentialStore store, InvenTreeApi? api})
    : _store = store,
      api = api ?? InvenTreeApi() {
    _allauth = AllauthClient(this.api);
    this.api.onUnauthorized = _onUnauthorized;
  }

  /// Session authentication requires the allauth "headless" API
  /// (same minimum as the official app).
  static const int minApiVersion = 314;

  final CredentialStore _store;
  final InvenTreeApi api;
  late final AllauthClient _allauth;

  AuthPhase _phase = AuthPhase.starting;
  AuthPhase get phase => _phase;

  ServerProfile? _profile;

  /// The stored server / username (to pre-fill the login form).
  ServerProfile? get profile => _profile;

  ConnectionInfo? _info;
  ConnectionInfo? get info => _info;

  String _message = "";

  /// Message to show on the login screen (error, or why the user was logged out).
  String get message => _message;

  bool _messageIsError = true;

  /// False if [message] is informational (e.g. "logged out") rather than an error.
  bool get messageIsError => _messageIsError;

  bool _canRetry = false;

  /// The stored session could not be verified because the server was unreachable.
  /// The session is kept, and the connection can be retried.
  bool get canRetry => _canRetry;

  bool _busy = false;
  bool get busy => _busy;

  AuthFlow? _pendingFlow;
  AuthFlow? get pendingFlow => _pendingFlow;

  Map<String, dynamic> _serverInfo = {};

  CertificateInfo? _pendingCertificate;

  /// A server certificate which failed validation - the user may choose to
  /// trust it (see [trustPendingCertificate]).
  CertificateInfo? get pendingCertificate => _pendingCertificate;

  bool _certificateChanged = false;

  /// True if [pendingCertificate] replaces a certificate the user had trusted.
  bool get certificateChanged => _certificateChanged;

  /// The certificate the user has trusted for the current server, if any.
  TrustedCertificate? get trustedCertificate => api.trustedCertificate;

  // Login in progress
  String _pendingServer = "";
  String _pendingUsername = "";

  // Session writes are queued, so they complete in order
  Future<void> _writes = Future.value();

  void _update({
    AuthPhase? phase,
    String? message,
    bool? busy,
    bool? canRetry,
    bool messageIsError = true,
  }) {
    if (phase != null && phase != _phase) {
      appLog.debug("auth", "State: ${_phase.name} -> ${phase.name}");
      _phase = phase;
    }
    if (message != null) {
      _message = message;
      _messageIsError = messageIsError;
      if (message.isNotEmpty) {
        appLog.add(
          messageIsError ? LogLevel.warning : LogLevel.info,
          "auth",
          message,
        );
      }
    }
    if (busy != null) _busy = busy;
    if (canRetry != null) _canRetry = canRetry;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Session persistence
  // ---------------------------------------------------------------------------

  void _attach(String server, SessionStore session) {
    api.configure(server, session);
    session.onChanged = () {
      if (identical(api.session, session)) _persistSession();
    };
  }

  /// Write the current session to secure storage. Returns false if the write failed.
  Future<bool> _persistSession() {
    final SessionStore session = api.session;
    final snapshot = session.snapshot();
    final String? data = session.isEmpty ? null : session.toJson();

    bool ok = false;

    _writes = _writes.then((_) async {
      try {
        await _store.saveSession(data);
        session.markPersisted(snapshot);
        ok = true;
      } catch (_) {
        ok = false;
      }
    });

    return _writes.then((_) => ok);
  }

  // ---------------------------------------------------------------------------
  // Launch: restore a stored session
  // ---------------------------------------------------------------------------

  /// Check for a stored session, and verify it with the server.
  /// Ends in [AuthPhase.connected] or [AuthPhase.loggedOut].
  Future<void> restore() async {
    _update(phase: AuthPhase.starting, message: "", canRetry: false);

    try {
      _profile = await _store.loadProfile();
    } catch (_) {
      _profile = null;
    }

    final ServerProfile? profile = _profile;

    if (profile == null) {
      _update(phase: AuthPhase.loggedOut);
      return;
    }

    String? data;

    try {
      data = await _store.loadSession();
    } catch (_) {
      data = null;
    }

    final SessionStore session = SessionStore.fromJson(profile.server, data);

    _attach(profile.server, session);
    await _loadTrust(profile.server);

    appLog.info(
      "auth",
      "Launch: stored profile for ${profile.server} "
          "(${session.hasSession ? "session found" : "no session"})",
    );

    // Stored cookies belong to a different server address - remove them
    if (session.rejected) {
      await _persistSession();
    }

    if (!session.hasSession) {
      _update(phase: AuthPhase.loggedOut);
      return;
    }

    await _connect(profile.username);
  }

  /// Retry verifying the stored session (after the server was unreachable).
  Future<void> retry() async {
    final ServerProfile? profile = _profile;

    if (profile == null || !api.session.hasSession) {
      _update(phase: AuthPhase.loggedOut, canRetry: false);
      return;
    }

    _update(phase: AuthPhase.starting, message: "", canRetry: false);

    await _connect(profile.username);
  }

  /// Check the server, then verify the session by requesting the current user.
  Future<void> _connect(String username) async {
    final String? serverError = await _checkServer();

    if (serverError != null) {
      _update(
        phase: AuthPhase.loggedOut,
        message: serverError,
        busy: false,
        canRetry: api.session.hasSession,
      );
      return;
    }

    final ApiResponse me = await api.get("user/me/");

    if (me.isSuccess) {
      final ApiResponse rolesResponse = await api.get("user/me/roles/");

      if (!rolesResponse.isSuccess) {
        _update(
          phase: AuthPhase.loggedOut,
          message: rolesResponse.isValid
              ? "Could not check your permissions (status ${rolesResponse.statusCode})."
              : describeFailure(rolesResponse),
          busy: false,
          canRetry: api.session.hasSession,
        );
        return;
      }

      final UserRoles roles = UserRoles.fromJson(rolesResponse.asMap());
      final Map<String, dynamic> user = me.asMap();
      final String fullName = [
        user["first_name"],
        user["last_name"],
      ].whereType<String>().where((s) => s.isNotEmpty).join(" ");

      _info = ConnectionInfo(
        server: api.server,
        username: (user["username"] ?? username).toString(),
        fullName: fullName,
        serverVersion: (_serverInfo["version"] ?? "").toString(),
        instanceName: (_serverInfo["instance"] ?? "").toString(),
        apiVersion: (_serverInfo["apiVersion"] as int?) ?? 0,
        roles: roles,
      );

      appLog.info(
        "auth",
        "Connected to ${api.server} as ${_info!.username} "
            "(InvenTree ${_info!.serverVersion}, API ${_info!.apiVersion})",
      );
      if (roles.missing.isNotEmpty) {
        appLog.warning(
          "auth",
          "Missing permissions: ${roles.missing.join("; ")}",
        );
      }

      _update(
        phase: AuthPhase.connected,
        message: "",
        busy: false,
        canRetry: false,
      );
      return;
    }

    // Not an authentication problem (e.g. network error, server error)
    // - keep the session, as it may still be valid
    if (!me.isValid) {
      _update(
        phase: AuthPhase.loggedOut,
        message: describeFailure(me),
        busy: false,
        canRetry: api.session.hasSession,
      );
      return;
    }

    if (me.statusCode == 401 || me.statusCode == 403) {
      String message = "Your session has expired. Please log in again.";

      // The server requires MFA to be configured for this user
      if (me.asMap()["id"] == FLOW_MFA_REGISTER) {
        message =
            "This account must set up two-factor authentication in the "
            "InvenTree web interface before it can be used in the app.";
      }

      api.session.clearAuthCookies();
      await _persistSession();

      _update(
        phase: AuthPhase.loggedOut,
        message: message,
        busy: false,
        canRetry: false,
      );
      return;
    }

    _update(
      phase: AuthPhase.loggedOut,
      message:
          "Server returned status ${me.statusCode} when checking the login.",
      busy: false,
      canRetry: api.session.hasSession,
    );
  }

  /// Check the server is reachable, is InvenTree, and is recent enough.
  /// Returns an error message, or null if OK.
  Future<String?> _checkServer() async {
    _pendingCertificate = null;
    api.lastRejectedCertificate = null;

    final ApiResponse response = await api.get("");

    if (!response.isValid) {
      final CertificateInfo? cert = api.lastRejectedCertificate;

      if (response.failure == ApiFailure.certificate && cert != null) {
        _pendingCertificate = cert;
        _certificateChanged = api.trustedCertificate != null;
        return _certificateChanged
            ? "WARNING: the server's security certificate has CHANGED since you trusted it. "
                  "This can happen when the certificate is renewed - but it can also mean "
                  "the connection is being intercepted."
            : "The server's security certificate is not trusted (for example, it is self-signed).";
      }

      return describeFailure(response);
    }

    if (!response.isSuccess) {
      return "Server returned status ${response.statusCode}. Check the server address.";
    }

    final Map<String, dynamic> data = response.asMap();

    if (data["server"] != "InvenTree") {
      return "This address does not appear to be an InvenTree server.";
    }

    final int apiVersion = (data["apiVersion"] as int?) ?? 0;

    if (apiVersion < minApiVersion) {
      return "The InvenTree server is too old (API version $apiVersion, "
          "this app requires $minApiVersion or newer). Please update the server.";
    }

    _serverInfo = data;

    return null;
  }

  // ---------------------------------------------------------------------------
  // Login
  // ---------------------------------------------------------------------------

  /// Log in with username and password.
  /// Ends in [AuthPhase.connected], [AuthPhase.mfaRequired] or [AuthPhase.loggedOut] (with a message).
  Future<void> login(
    String serverInput,
    String username,
    String password,
  ) async {
    if (_busy) return;

    final String? server = normaliseServerUrl(serverInput);

    if (server == null) {
      _update(
        message:
            "Enter a valid server address, e.g. https://inventree.example.com",
      );
      return;
    }

    username = username.trim();

    if (username.isEmpty || password.isEmpty) {
      _update(message: "Enter your username and password.");
      return;
    }

    _update(busy: true, message: "", canRetry: false);

    // Same server: keep any other cookies (e.g. the MFA "trusted device" cookie).
    // Different server: start with an empty jar.
    final SessionStore session = api.server == server
        ? api.session
        : SessionStore(server: server);

    // Starting a fresh login - drop any old session (also avoids a 409 conflict)
    session.clearAuthCookies();

    _attach(server, session);
    await _loadTrust(server);
    await _persistSession();

    appLog.info("auth", "Login: $username at $server");

    _pendingServer = server;
    _pendingUsername = username;

    final String? serverError = await _checkServer();

    if (serverError != null) {
      _fail(serverError);
      return;
    }

    final AuthConfig config = await _allauth.getConfig();

    if (!await _allauth.ensureCsrf()) {
      _fail(
        "The server did not provide a CSRF token, so login is not possible.",
      );
      return;
    }

    final AuthResult result = await _allauth.loginPassword(
      login: username,
      password: password,
      field: config.loginField,
    );

    await _handleResult(result);
  }

  /// Submit a code (TOTP or recovery code) for a pending MFA flow.
  Future<void> submitMfa(String code, {bool trustDevice = false}) async {
    if (_busy || _phase != AuthPhase.mfaRequired) return;

    code = code.trim();

    if (code.isEmpty) {
      _update(message: "Enter the code from your authenticator app.");
      return;
    }

    _update(busy: true, message: "");

    AuthResult result = await _allauth.authenticateMfa(code);

    if (result.pendingFlow?.id == FLOW_MFA_TRUST) {
      result = await _allauth.trustDevice(trustDevice);
    }

    // Wrong code - stay on the MFA step
    if (result.status == AuthStatus.failed && result.statusCode == 400) {
      _update(
        busy: false,
        message: result.errorMessage.isEmpty
            ? "Incorrect code."
            : result.errorMessage,
      );
      return;
    }

    await _handleResult(result);
  }

  /// Abandon a pending MFA step and return to the login form.
  Future<void> cancelMfa() async {
    _pendingFlow = null;
    api.session.clearAuthCookies();
    await _persistSession();
    _update(phase: AuthPhase.loggedOut, message: "", busy: false);
  }

  Future<void> _handleResult(AuthResult result) async {
    switch (result.status) {
      case AuthStatus.authenticated:
        _pendingFlow = null;
        await _completeLogin();

      case AuthStatus.flowPending:
        final AuthFlow flow = result.pendingFlow!;

        if (flow.isSupportedMfa) {
          _pendingFlow = flow;
          _update(phase: AuthPhase.mfaRequired, busy: false, message: "");
        } else if (flow.id == FLOW_MFA_REGISTER) {
          _fail(
            "This account must set up two-factor authentication in the "
            "InvenTree web interface before it can be used in the app.",
          );
        } else {
          _fail(
            "The server requires a login step this app does not support (${flow.id}).",
          );
        }

      case AuthStatus.failed:
        // The server already has an authenticated session for these cookies
        if (result.statusCode == 409) {
          api.session.clearAuthCookies();
          await _persistSession();
          _fail("The server reported an existing session. Please try again.");
        } else {
          _fail(
            result.errorMessage.isNotEmpty
                ? result.errorMessage
                : "Login failed (status ${result.statusCode}).",
          );
        }
    }
  }

  /// Login completed - persist the session and profile, then verify the connection.
  ///
  /// If the session cannot be saved, the login is treated as failed: the new
  /// session is ended on the server and discarded, rather than leaving the
  /// user apparently logged in without a stored session.
  Future<void> _completeLogin() async {
    if (!await _persistSession()) {
      await _allauth.logout();
      api.session.clearAuthCookies();
      _fail("Logged in, but the session could not be saved on this device.");
      return;
    }

    final profile = ServerProfile(
      server: _pendingServer,
      username: _pendingUsername,
    );

    try {
      await _store.saveProfile(profile);
    } catch (_) {
      // Login still works for this run; auto-login will not.
    }

    _profile = profile;

    await _connect(_pendingUsername);
  }

  void _fail(String message) {
    _pendingFlow = null;
    _update(phase: AuthPhase.loggedOut, message: message, busy: false);
  }

  // ---------------------------------------------------------------------------
  // Self-signed certificates
  // ---------------------------------------------------------------------------

  Future<void> _loadTrust(String server) async {
    TrustedCertificate? trusted;
    try {
      trusted = TrustedCertificate.fromJson(
        await _store.loadTrustedCertificate(),
      );
    } catch (_) {
      trusted = null;
    }
    // Only ever applies to the server it was trusted for
    api.trustedCertificate =
        (trusted != null && trusted.origin == serverOrigin(server))
        ? trusted
        : null;
  }

  /// Trust [pendingCertificate] for the current server. The caller then
  /// retries the login / connection. Returns false if it could not be saved.
  Future<bool> trustPendingCertificate() async {
    final CertificateInfo? cert = _pendingCertificate;
    final Uri? server = Uri.tryParse(api.server);

    if (cert == null ||
        server == null ||
        server.host.toLowerCase() != cert.host.toLowerCase() ||
        server.port != cert.port) {
      return false;
    }

    final trusted = TrustedCertificate(
      origin: serverOrigin(api.server),
      der: cert.der,
    );

    try {
      await _store.saveTrustedCertificate(trusted.toJson());
    } catch (_) {
      _update(message: "The certificate could not be saved on this device.");
      return false;
    }

    api.trustedCertificate = trusted;
    _pendingCertificate = null;
    _certificateChanged = false;

    appLog.warning(
      "tls",
      "User trusted certificate for ${trusted.origin}: SHA-256 ${trusted.fingerprint}",
    );
    _update(message: "");
    return true;
  }

  /// Do not trust the pending certificate.
  void rejectPendingCertificate() {
    if (_pendingCertificate == null) return;
    appLog.info("tls", "User did not trust the certificate");
    _pendingCertificate = null;
    notifyListeners();
  }

  /// Remove the trusted certificate (the next connection will ask again).
  Future<void> forgetTrustedCertificate() async {
    final TrustedCertificate? trusted = api.trustedCertificate;
    if (trusted == null) return;
    try {
      await _store.saveTrustedCertificate(null);
    } catch (_) {
      // Removed from memory regardless
    }
    appLog.info("tls", "Trusted certificate removed for ${trusted.origin}");
    api.trustedCertificate = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Logout / expiry
  // ---------------------------------------------------------------------------

  /// End the session on the server and remove it from the device.
  /// The server address and username are kept, to pre-fill the login form.
  Future<void> logout() async {
    if (_busy) return;

    _update(busy: true);

    if (api.session.hasSession) {
      await _allauth.logout();
    }

    // Keep other cookies (e.g. MFA "trusted device"), as a browser does on logout
    api.session.clearAuthCookies();
    await _persistSession();

    _info = null;
    appLog.info("auth", "Logged out");
    _update(
      phase: AuthPhase.loggedOut,
      message: "You have been logged out.",
      messageIsError: false,
      busy: false,
      canRetry: false,
    );
  }

  /// An API request was rejected with 401 while connected - the session has ended.
  void _onUnauthorized() {
    if (_phase != AuthPhase.connected) return;

    api.session.clearAuthCookies();
    _persistSession();

    _info = null;
    _update(
      phase: AuthPhase.loggedOut,
      message: "Your session has expired. Please log in again.",
      canRetry: false,
    );
  }
}
