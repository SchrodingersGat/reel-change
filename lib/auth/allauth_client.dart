// Adapted from the official InvenTree mobile app (inventree-app),
// lib/auth/allauth_client.dart at commit 085dad4.
// Changes: takes the API client by injection; SSO provider login removed.
//
// MIT License - Copyright (c) 2019 InvenTree. See THIRD_PARTY_NOTICES.md.

import "package:inventree_smt/auth/auth_result.dart";
import "package:inventree_smt/core/api_client.dart";

/*
 * Thin wrapper around the allauth "headless" API endpoints exposed by the server.
 * InvenTree only exposes the "browser" client, which uses session + CSRF cookies.
 */
class AllauthClient {
  const AllauthClient(this._api);

  static const String URL_CONFIG = "auth/v1/config";
  static const String URL_SESSION = "auth/v1/auth/session";
  static const String URL_LOGIN = "auth/v1/auth/login";
  static const String URL_MFA_AUTHENTICATE = "auth/v1/auth/2fa/authenticate";
  static const String URL_MFA_TRUST = "auth/v1/auth/2fa/trust";

  final InvenTreeApi _api;

  // Server authentication configuration
  Future<AuthConfig> getConfig() async {
    return AuthConfig.fromResponse(await _api.get(URL_CONFIG));
  }

  /*
   * Ensure that we have a CSRF token before making any "unsafe" requests.
   * Requesting the session status causes the server to issue a CSRF cookie.
   */
  Future<bool> ensureCsrf() async {
    if (_api.session.hasCsrfToken) {
      return true;
    }

    await _api.get(URL_SESSION);

    return _api.session.hasCsrfToken;
  }

  Future<AuthResult> _post(String url, Map<String, dynamic> body) async {
    final ApiResponse response = await _api.post(url, body: body);

    if (!response.isValid) {
      return AuthResult.failed(describeFailure(response));
    }

    return AuthResult.fromResponse(response);
  }

  // Login with username (or email) and password
  Future<AuthResult> loginPassword({
    required String login,
    required String password,
    String field = "username",
  }) {
    return _post(URL_LOGIN, {field: login, "password": password});
  }

  // Provide a TOTP (or recovery) code to complete a pending MFA flow
  Future<AuthResult> authenticateMfa(String code) {
    return _post(URL_MFA_AUTHENTICATE, {"code": code});
  }

  // Respond to a pending "trust this device" flow
  Future<AuthResult> trustDevice(bool trust) {
    return _post(URL_MFA_TRUST, {"trust": trust});
  }

  // End the server session (the server responds with 401 on success)
  Future<void> logout() async {
    await _api.delete(URL_SESSION);
  }
}

/// A user-facing description of a transport failure.
String describeFailure(ApiResponse response) {
  switch (response.failure) {
    case ApiFailure.none:
      return "Server returned status ${response.statusCode}";
    case ApiFailure.invalidUrl:
      return "Invalid server address";
    case ApiFailure.network:
      return "Could not connect to the server. Check the address and your network connection.";
    case ApiFailure.timeout:
      return "The server did not respond in time.";
    case ApiFailure.certificate:
      return "The server's security certificate could not be verified.";
    case ApiFailure.redirect:
      return "The server redirected the request. Check the server address (http vs https, sub-path).";
    case ApiFailure.other:
      return "Unexpected error communicating with the server.";
  }
}
