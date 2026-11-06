// SessionStore tests ported from the official InvenTree mobile app (inventree-app),
// test/auth_test.dart at commit 085dad4.
//
// MIT License - Copyright (c) 2019 InvenTree. See THIRD_PARTY_NOTICES.md.

// ignore_for_file: unnecessary_brace_in_string_interps

import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/auth/session_store.dart";

const String server = "https://inventree.example.com";

Cookie _cookie(
  String name,
  String value, {
  String? domain,
  String? path,
  int? maxAge,
  DateTime? expires,
  bool secure = false,
}) {
  final cookie = Cookie(name, value);
  cookie.domain = domain;
  cookie.path = path;
  cookie.maxAge = maxAge;
  cookie.expires = expires;
  cookie.secure = secure;
  return cookie;
}

void main() {
  final Uri serverUri = Uri.parse("${server}/api/part/");

  group("SessionStore:", () {
    test("Capture and send cookies", () {
      final store = SessionStore(server: server);

      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", path: "/"),
        _cookie(CSRF_COOKIE_NAME, "xyz", path: "/"),
      ]);

      expect(store.hasSession, equals(true));
      expect(store.csrfToken, equals("xyz"));

      final String header = store.cookieHeader(serverUri);
      expect(header, contains("sessionid=abc"));
      expect(header, contains("csrftoken=xyz"));
    });

    test("Cookies are never accepted from or sent to another host", () {
      final store = SessionStore(server: server);

      // Cookie received from a different host
      store.capture(Uri.parse("https://evil.example.org/"), [
        _cookie(SESSION_COOKIE_NAME, "abc"),
      ]);

      expect(store.hasSession, equals(false));

      // Cookie for a domain the server does not belong to
      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", domain: "other.com"),
      ]);

      expect(store.hasSession, equals(false));

      store.capture(serverUri, [_cookie(SESSION_COOKIE_NAME, "abc")]);
      expect(store.hasSession, equals(true));

      expect(store.cookieHeader(Uri.parse("https://evil.example.org/")), "");

      // Same host, different scheme / port
      expect(
        store.cookieHeader(Uri.parse("http://inventree.example.com/")),
        "",
      );
      expect(
        store.cookieHeader(Uri.parse("https://inventree.example.com:8443/")),
        "",
      );
    });

    test("Expiry and deletion", () {
      final store = SessionStore(server: server);

      store.capture(serverUri, [_cookie(SESSION_COOKIE_NAME, "abc")]);
      expect(store.hasSession, equals(true));

      // Max-Age=0 deletes the cookie
      store.capture(serverUri, [_cookie(SESSION_COOKIE_NAME, "", maxAge: 0)]);
      expect(store.hasSession, equals(false));

      // Expires in the past deletes the cookie
      store.capture(serverUri, [_cookie(SESSION_COOKIE_NAME, "abc")]);
      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", expires: DateTime(1970)),
      ]);
      expect(store.hasSession, equals(false));
    });

    test("Secure cookies are not sent over HTTP", () {
      final store = SessionStore(server: "http://inventree.local");
      final uri = Uri.parse("http://inventree.local/api/");

      store.capture(uri, [
        _cookie(SESSION_COOKIE_NAME, "abc", secure: true),
        _cookie(CSRF_COOKIE_NAME, "xyz"),
      ]);

      expect(store.cookieHeader(uri), equals("csrftoken=xyz"));
    });

    test("Path matching", () {
      final store = SessionStore(server: server);

      store.capture(serverUri, [_cookie("scoped", "1", path: "/api")]);

      expect(store.cookieHeader(Uri.parse("${server}/api/part/")), "scoped=1");
      expect(store.cookieHeader(Uri.parse("${server}/api")), "scoped=1");
      expect(store.cookieHeader(Uri.parse("${server}/apix/")), "");
      expect(store.cookieHeader(Uri.parse("${server}/web/")), "");
    });

    // A store which counts change notifications, and simulates each one being
    // persisted successfully (as saveSession() does)
    (SessionStore, int Function()) persistingStore() {
      final store = SessionStore(server: server);

      int changes = 0;

      store.onChanged = () {
        changes++;
        store.markPersisted(store.snapshot());
      };

      return (store, () => changes);
    }

    test("Change notification", () {
      final (store, changes) = persistingStore();

      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz", maxAge: 60)]);
      expect(changes(), equals(1));

      // Same value (and similar expiry) - no change reported
      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz", maxAge: 61)]);
      expect(changes(), equals(1));

      // New value
      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "abc", maxAge: 60)]);
      expect(changes(), equals(2));

      // Deleted
      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "", maxAge: 0)]);
      expect(changes(), equals(3));
    });

    test("Sliding expiry is persisted once it has moved by an hour", () {
      final (store, changes) = persistingStore();
      final DateTime base = DateTime.now().add(Duration(days: 14));

      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", expires: base),
      ]);
      expect(changes(), equals(1));

      // Each renewal is less than an hour after the previous one...
      store.capture(serverUri, [
        _cookie(
          SESSION_COOKIE_NAME,
          "abc",
          expires: base.add(Duration(minutes: 40)),
        ),
      ]);
      expect(changes(), equals(1));

      // ... but more than an hour after the persisted expiry
      store.capture(serverUri, [
        _cookie(
          SESSION_COOKIE_NAME,
          "abc",
          expires: base.add(Duration(minutes: 80)),
        ),
      ]);
      expect(changes(), equals(2));

      // Now compared against the new persisted expiry
      store.capture(serverUri, [
        _cookie(
          SESSION_COOKIE_NAME,
          "abc",
          expires: base.add(Duration(minutes: 120)),
        ),
      ]);
      expect(changes(), equals(2));
    });

    test("Cookie attribute changes are persisted", () {
      for (final changed in [
        _cookie(CSRF_COOKIE_NAME, "xyz", path: "/api/"),
        _cookie(CSRF_COOKIE_NAME, "xyz", secure: true),
        _cookie(CSRF_COOKIE_NAME, "xyz", domain: "example.com"),
      ]) {
        final (store, changes) = persistingStore();

        store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz")]);
        expect(changes(), equals(1));

        // Same value - but different path / secure / domain
        store.capture(serverUri, [changed]);
        expect(changes(), equals(2), reason: changed.toString());
      }
    });

    test("Changes are reported again after a failed write", () {
      final store = SessionStore(server: server);

      int changes = 0;
      bool writeSucceeds = false;

      store.onChanged = () {
        changes++;

        if (writeSucceeds) {
          store.markPersisted(store.snapshot());
        }
      };

      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz")]);
      expect(changes, equals(1));

      // Not persisted - so the same cookie is reported again (write retried)
      writeSucceeds = true;
      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz")]);
      expect(changes, equals(2));

      // Persisted - no further change
      store.capture(serverUri, [_cookie(CSRF_COOKIE_NAME, "xyz")]);
      expect(changes, equals(2));
    });

    test("Restored cookies are treated as persisted", () {
      final (original, _) = persistingStore();
      original.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", maxAge: 3600),
      ]);

      final restored = SessionStore.fromJson(server, original.toJson());

      int changes = 0;
      restored.onChanged = () => changes++;

      // Same cookie as stored - no write required
      restored.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", maxAge: 3600),
      ]);
      expect(changes, equals(0));
    });

    test("Clear auth cookies retains other cookies", () {
      final store = SessionStore(server: server);

      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc"),
        _cookie(CSRF_COOKIE_NAME, "xyz"),
        _cookie("mfa_trusted", "trusted"),
      ]);

      store.clearAuthCookies();

      expect(store.hasSession, equals(false));
      expect(store.hasCsrfToken, equals(false));
      expect(store.cookieHeader(serverUri), equals("mfa_trusted=trusted"));

      store.clear();
      expect(store.isEmpty, equals(true));
    });

    test("Serialization", () {
      final store = SessionStore(server: server);

      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc", maxAge: 3600),
        _cookie(CSRF_COOKIE_NAME, "xyz", secure: true),
        _cookie("expired", "old", expires: DateTime(1970)),
      ]);

      final restored = SessionStore.fromJson(server, store.toJson());

      expect(restored.hasSession, equals(true));
      expect(restored.csrfToken, equals("xyz"));
      expect(restored.cookieNames.length, equals(2));

      // Corrupt data results in an empty store
      expect(SessionStore.fromJson(server, "not-json").isEmpty, equals(true));
      expect(SessionStore.fromJson(server, null).isEmpty, equals(true));
    });

    test("Server origin", () {
      expect(
        serverOrigin("https://inventree.example.com"),
        equals("https://inventree.example.com:443"),
      );
      expect(
        serverOrigin("HTTPS://InvenTree.Example.com:443/inventree/"),
        equals("https://inventree.example.com:443"),
      );
      expect(
        serverOrigin("http://127.0.0.1:8000/"),
        equals("http://127.0.0.1:8000"),
      );
      expect(serverOrigin("not a url"), isEmpty);
      expect(serverOrigin(""), isEmpty);
    });

    test("Stored cookies are only restored for the issuing origin", () {
      final store = SessionStore(server: server);
      store.capture(serverUri, [
        _cookie(SESSION_COOKIE_NAME, "abc"),
        _cookie(CSRF_COOKIE_NAME, "xyz"),
        _cookie("mfa_trusted", "trusted"),
      ]);

      final String data = store.toJson();

      // Same origin - including an explicit default port, a different path or case
      for (final address in [
        server,
        "https://inventree.example.com:443",
        "https://inventree.example.com/inventree/",
        "https://INVENTREE.example.com/",
      ]) {
        final restored = SessionStore.fromJson(address, data);
        expect(restored.rejected, equals(false), reason: address);
        expect(restored.hasSession, equals(true), reason: address);
      }

      // Different origin - no cookies at all are restored (including MFA trust)
      for (final address in [
        "http://inventree.example.com",
        "https://inventree.example.com:8443",
        "http://inventree.example.com:443",
        "https://other.example.com",
        "https://example.com",
        "",
      ]) {
        final restored = SessionStore.fromJson(address, data);
        expect(restored.rejected, equals(true), reason: address);
        expect(restored.isEmpty, equals(true), reason: address);
        expect(
          restored.cookieHeader(Uri.parse("${address}/api/")),
          isEmpty,
          reason: address,
        );
      }
    });

    test("Stored cookies without an origin are not restored", () {
      // Format used before the origin was recorded
      const String legacy =
          '[{"name": "sessionid", "value": "abc", "domain": "inventree.example.com"}]';

      final restored = SessionStore.fromJson(server, legacy);

      expect(restored.rejected, equals(true));
      expect(restored.isEmpty, equals(true));

      expect(
        SessionStore.fromJson(server, '{"cookies": []}').rejected,
        equals(true),
      );
    });

    test("Set-Cookie header parsing", () {
      // package:http folds multiple headers into one, separated by a comma
      final values = splitSetCookieHeader(
        [
          "sessionid=abc; expires=Thu, 01 Jan 2099 00:00:00 GMT; HttpOnly; Path=/",
          "csrftoken=xyz; expires=Fri, 02 Jan 2099 00:00:00 GMT; Path=/",
        ].join(","),
      );

      expect(values.length, equals(2));
      expect(values[0], startsWith("sessionid=abc"));
      expect(values[1], startsWith("csrftoken=xyz"));

      final store = SessionStore(server: server);

      // A malformed cookie does not prevent the others from being stored
      store.captureHeaders(serverUri, [...values, "=bad=;;"]);

      expect(store.hasSession, equals(true));
      expect(store.csrfToken, equals("xyz"));
    });
  });
}
