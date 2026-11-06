/*
 * Login / auto-login flow tests, against a fake InvenTree server on localhost.
 */

import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/api_client.dart";
import "package:inventree_smt/core/credential_store.dart";

import "fake_inventree.dart";

void main() {
  late FakeInvenTree server;
  late MemoryCredentialStore store;

  setUp(() async {
    server = await FakeInvenTree.start();
    store = MemoryCredentialStore();
  });

  tearDown(() => server.close());

  AuthService newService() => AuthService(store: store);

  group("Server address:", () {
    test("Normalisation", () {
      expect(
        normaliseServerUrl("inventree.example.com"),
        "https://inventree.example.com/",
      );
      expect(
        normaliseServerUrl(" http://localhost:8000 "),
        "http://localhost:8000/",
      );
      expect(
        normaliseServerUrl("HTTPS://Host/inventree"),
        "https://host/inventree/",
      );
      expect(normaliseServerUrl(""), isNull);
      expect(normaliseServerUrl("ftp://host"), isNull);
      expect(normaliseServerUrl("https://user:pw@host"), isNull);
      expect(normaliseServerUrl("https://host/?a=b"), isNull);
    });

    test("Insecure remote detection", () {
      expect(isInsecureRemote("http://localhost:8000/"), isFalse);
      expect(isInsecureRemote("http://127.0.0.1:8000/"), isFalse);
      expect(isInsecureRemote("http://inventree.local/"), isTrue);
      expect(isInsecureRemote("https://inventree.local/"), isFalse);
    });
  });

  group("Launch:", () {
    test("No stored profile - login screen", () async {
      final auth = newService();
      await auth.restore();

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.message, isEmpty);
      expect(server.requests, isEmpty);
    });

    test(
      "Stored profile but no session - login screen, form pre-filled",
      () async {
        store.profile = ServerProfile(server: server.url, username: "reader");

        final auth = newService();
        await auth.restore();

        expect(auth.phase, AuthPhase.loggedOut);
        expect(auth.profile?.username, "reader");
        expect(server.requests, isEmpty);
      },
    );

    test("Valid stored session - auto-login", () async {
      // Log in once, then start a new app instance with the same storage
      final first = newService();
      await first.login(server.url, "reader", "secret");
      expect(first.phase, AuthPhase.connected);

      final second = newService();
      await second.restore();

      expect(second.phase, AuthPhase.connected);
      expect(second.info?.username, "reader");
      expect(second.info?.serverVersion, "1.8.0 test");
      // No new login was made
      expect(server.loginBodies.length, 1);
    });

    test("Expired stored session - login screen, session removed", () async {
      final first = newService();
      await first.login(server.url, "reader", "secret");

      server.expireAllSessions();

      final second = newService();
      await second.restore();

      expect(second.phase, AuthPhase.loggedOut);
      expect(second.message, contains("expired"));
      expect(second.canRetry, isFalse);
      expect(store.session ?? "", isNot(contains("sessionid")));
      // Username kept for convenience
      expect(second.profile?.username, "reader");
    });

    test(
      "Server unreachable - login screen, session kept, retry offered",
      () async {
        final first = newService();
        await first.login(server.url, "reader", "secret");
        final String url = server.url;
        final String? stored = store.session;

        await server.close();

        final second = newService();
        await second.restore();

        expect(second.phase, AuthPhase.loggedOut);
        expect(second.canRetry, isTrue);
        expect(second.message, contains("Could not connect"));
        expect(store.session, stored);
        expect(second.profile?.server, url);
      },
    );

    test("Server too old", () async {
      final first = newService();
      await first.login(server.url, "reader", "secret");

      server.apiVersion = 300;

      final second = newService();
      await second.restore();

      expect(second.phase, AuthPhase.loggedOut);
      expect(second.message, contains("too old"));
    });
  });

  group("Login:", () {
    test("Successful login stores the session, never the password", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.connected);
      expect(auth.info?.username, "reader");
      expect(auth.info?.fullName, "Test User");
      expect(server.csrfFailures, 0);

      expect(store.profile?.server, server.url);
      expect(store.profile?.username, "reader");

      final String session = store.session ?? "";
      expect(session, contains("sessionid"));
      expect(session, isNot(contains("secret")));

      final Map<String, dynamic> body =
          json.decode(server.loginBodies.single) as Map<String, dynamic>;
      expect(body, {"username": "reader", "password": "secret"});
    });

    test("Wrong password", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "wrong");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.message, contains("not correct"));
      expect(auth.busy, isFalse);
      expect(store.session ?? "", isNot(contains("sessionid")));
    });

    test(
      "Invalid address and missing fields are rejected without a request",
      () async {
        final auth = newService();

        await auth.login("ftp://nope", "reader", "secret");
        expect(auth.message, contains("valid server address"));

        await auth.login(server.url, "", "secret");
        expect(auth.message, contains("username and password"));

        await auth.login(server.url, "reader", "");
        expect(auth.message, contains("username and password"));

        expect(server.requests, isEmpty);
      },
    );

    test("Not an InvenTree server", () async {
      final auth = newService();
      await auth.login("${server.url}not-inventree/", "reader", "secret");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(server.loginBodies, isEmpty);
    });

    test("Session save failure is treated as a failed login", () async {
      store.failWrites = true;

      final auth = newService();
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.message, contains("could not be saved"));
      // The new session was ended on the server
      expect(server.sessions, isEmpty);
    });

    test("Logging in again while a session exists does not conflict", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.connected);
    });
  });

  group("MFA:", () {
    setUp(() => server.mfaUsers.add("reader"));

    test("Code required, then accepted", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.mfaRequired);
      expect(auth.pendingFlow?.types, ["totp"]);

      await auth.submitMfa("123456");

      expect(auth.phase, AuthPhase.connected);
      expect(store.session, contains("sessionid"));
    });

    test("Wrong code stays on the MFA step", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");
      await auth.submitMfa("000000");

      expect(auth.phase, AuthPhase.mfaRequired);
      expect(auth.message, contains("Incorrect"));
    });

    test("Cancel returns to the login form", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");
      await auth.cancelMfa();

      expect(auth.phase, AuthPhase.loggedOut);
      expect(store.session ?? "", isNot(contains("sessionid")));
    });
  });

  group("Logout and expiry:", () {
    test(
      "Logout ends the server session and removes it from the device",
      () async {
        final auth = newService();
        await auth.login(server.url, "reader", "secret");

        await auth.logout();

        expect(auth.phase, AuthPhase.loggedOut);
        expect(auth.messageIsError, isFalse);
        expect(server.sessions, isEmpty);
        expect(store.session ?? "", isNot(contains("sessionid")));
        expect(store.profile?.username, "reader");

        // Next launch goes to the login screen
        final next = newService();
        await next.restore();
        expect(next.phase, AuthPhase.loggedOut);
      },
    );

    test("A 401 while connected logs the user out", () async {
      final auth = newService();
      await auth.login(server.url, "reader", "secret");

      server.expireAllSessions();
      await auth.api.get("user/me/");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.message, contains("expired"));
    });
  });
}
