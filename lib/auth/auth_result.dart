// Adapted from the official InvenTree mobile app (inventree-app),
// lib/auth/auth_result.dart at commit 085dad4.
// Changes: uses this app's ApiResponse; SSO provider types removed.
//
// MIT License - Copyright (c) 2019 InvenTree. See THIRD_PARTY_NOTICES.md.

import "package:inventree_smt/core/api_client.dart";

/*
 * Data types for responses from the (allauth headless) authentication API.
 * Ref: https://docs.allauth.org/en/latest/headless/openapi-specification/
 */

// Flow identifiers (as returned by the server in the "flows" list)
const String FLOW_LOGIN = "login";
const String FLOW_MFA_AUTHENTICATE = "mfa_authenticate";
const String FLOW_MFA_TRUST = "mfa_trust";
const String FLOW_MFA_REGISTER = "mfa_register";

// MFA authenticator types
const String MFA_TYPE_TOTP = "totp";
const String MFA_TYPE_RECOVERY_CODES = "recovery_codes";

// MFA types which the app is able to complete
const List<String> SUPPORTED_MFA_TYPES = [
  MFA_TYPE_TOTP,
  MFA_TYPE_RECOVERY_CODES,
];

enum AuthStatus {
  // User is fully authenticated
  authenticated,
  // Further action is required (see AuthResult.pendingFlow)
  flowPending,
  // Authentication failed (see AuthResult.errors)
  failed,
}

/*
 * An authentication "flow" - e.g. a pending MFA step
 */
class AuthFlow {
  AuthFlow({required this.id, this.isPending = false, this.types = const []});

  factory AuthFlow.fromJson(Map<String, dynamic> json) {
    List<String> types = [];

    if (json["types"] is List) {
      types = (json["types"] as List).map((t) => t.toString()).toList();
    }

    return AuthFlow(
      id: (json["id"] ?? "").toString(),
      isPending: (json["is_pending"] ?? false) == true,
      types: types,
    );
  }

  final String id;
  final bool isPending;

  // Available authenticator types (for MFA flows)
  final List<String> types;

  // Can the app complete this MFA flow (i.e. supports at least one of the types)?
  bool get isSupportedMfa =>
      id == FLOW_MFA_AUTHENTICATE &&
      types.any((t) => SUPPORTED_MFA_TYPES.contains(t));

  bool get supportsRecoveryCodes => types.contains(MFA_TYPE_RECOVERY_CODES);

  @override
  String toString() => "AuthFlow($id, pending=$isPending, types=$types)";
}

/*
 * Result of an authentication request
 */
class AuthResult {
  AuthResult({
    required this.status,
    this.statusCode = -1,
    this.pendingFlow,
    this.errors = const [],
  });

  factory AuthResult.failed(String error, {int statusCode = -1}) => AuthResult(
    status: AuthStatus.failed,
    statusCode: statusCode,
    errors: error.isEmpty ? [] : [error],
  );

  /*
   * Construct an AuthResult from an allauth API response
   */
  factory AuthResult.fromResponse(ApiResponse response) {
    final int statusCode = response.statusCode;
    final Map<String, dynamic> body = response.asMap();

    final Map<String, dynamic> data = body["data"] is Map<String, dynamic>
        ? body["data"] as Map<String, dynamic>
        : {};

    final Map<String, dynamic> meta = body["meta"] is Map<String, dynamic>
        ? body["meta"] as Map<String, dynamic>
        : {};

    if (statusCode == 200 && meta["is_authenticated"] == true) {
      return AuthResult(
        status: AuthStatus.authenticated,
        statusCode: statusCode,
      );
    }

    if (statusCode == 401 && data["flows"] is List) {
      for (var flow in data["flows"] as List) {
        if (flow is Map<String, dynamic>) {
          final AuthFlow f = AuthFlow.fromJson(flow);

          if (f.isPending) {
            return AuthResult(
              status: AuthStatus.flowPending,
              statusCode: statusCode,
              pendingFlow: f,
            );
          }
        }
      }
    }

    return AuthResult(
      status: AuthStatus.failed,
      statusCode: statusCode,
      errors: extractErrors(body),
    );
  }

  final AuthStatus status;
  final int statusCode;
  final AuthFlow? pendingFlow;
  final List<String> errors;

  bool get authenticated => status == AuthStatus.authenticated;

  String get errorMessage => errors.join("\n");

  @override
  String toString() =>
      "AuthResult(${status.name}, status=$statusCode, flow=$pendingFlow)";
}

/*
 * Extract human-readable error messages from an allauth (or DRF) error response
 */
List<String> extractErrors(Map<String, dynamic> body) {
  List<String> errors = [];

  if (body["errors"] is List) {
    for (var error in body["errors"] as List) {
      if (error is Map && error["message"] != null) {
        errors.add(error["message"].toString());
      }
    }
  }

  for (final key in ["detail", "error", "message"]) {
    if (errors.isEmpty && body[key] is String) {
      errors.add(body[key] as String);
    }
  }

  return errors;
}

/*
 * Server authentication configuration
 */
class AuthConfig {
  AuthConfig({this.loginMethods = const ["username"]});

  factory AuthConfig.fromResponse(ApiResponse response) {
    final Map<String, dynamic> body = response.asMap();

    if (!response.isSuccess || body["data"] is! Map<String, dynamic>) {
      return AuthConfig();
    }

    final Map<String, dynamic> data = body["data"] as Map<String, dynamic>;

    final Map<String, dynamic> account = data["account"] is Map<String, dynamic>
        ? data["account"] as Map<String, dynamic>
        : {};

    List<String> loginMethods = [];

    if (account["login_methods"] is List) {
      loginMethods = (account["login_methods"] as List)
          .map((m) => m.toString())
          .toList();
    }

    return AuthConfig(
      loginMethods: loginMethods.isEmpty ? ["username"] : loginMethods,
    );
  }

  final List<String> loginMethods;

  // Which field should the "login" value be sent as?
  String get loginField =>
      (!loginMethods.contains("username") && loginMethods.contains("email"))
      ? "email"
      : "username";
}
