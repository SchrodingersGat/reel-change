/*
 * Login against a real InvenTree server. Skipped unless configured:
 *
 *   INVENTREE_TEST_SERVER=http://localhost:8000
 *   INVENTREE_TEST_USERNAME=...
 *   INVENTREE_TEST_PASSWORD=...
 *
 * Credentials are read from the environment only - never commit them.
 */

@Tags(["live"])
library;

import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/credential_store.dart";

void main() {
  final env = Platform.environment;
  final String server = env["INVENTREE_TEST_SERVER"] ?? "";
  final String username = env["INVENTREE_TEST_USERNAME"] ?? "";
  final String password = env["INVENTREE_TEST_PASSWORD"] ?? "";

  final String? skip = (server.isEmpty || username.isEmpty || password.isEmpty)
      ? "Set INVENTREE_TEST_SERVER / _USERNAME / _PASSWORD to run"
      : null;

  test("Login, auto-login, logout", () async {
    final store = MemoryCredentialStore();

    final auth = AuthService(store: store);
    await auth.login(server, username, password);
    expect(auth.phase, AuthPhase.connected, reason: auth.message);
    expect(auth.info?.username, username);

    // New instance, same storage: auto-login with the stored session
    final relaunch = AuthService(store: store);
    await relaunch.restore();
    expect(relaunch.phase, AuthPhase.connected, reason: relaunch.message);

    await relaunch.logout();
    expect(relaunch.phase, AuthPhase.loggedOut);

    // Session no longer valid
    final afterLogout = AuthService(store: store);
    await afterLogout.restore();
    expect(afterLogout.phase, AuthPhase.loggedOut);
  }, skip: skip);

  test("Wrong password is rejected", () async {
    final auth = AuthService(store: MemoryCredentialStore());
    await auth.login(server, username, "$password-wrong");
    expect(auth.phase, AuthPhase.loggedOut);
    expect(auth.message, isNotEmpty);
  }, skip: skip);
}
