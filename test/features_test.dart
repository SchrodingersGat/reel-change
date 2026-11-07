/*
 * Permissions, in-app log and preferences.
 */

import "package:flutter_test/flutter_test.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/auth/session_store.dart";
import "package:reel_change/core/app_log.dart";
import "package:reel_change/core/credential_store.dart";
import "package:reel_change/core/settings_store.dart";
import "package:reel_change/inventree/models.dart";

import "fake_inventree.dart";

void main() {
  group("Permissions:", () {
    late FakeInvenTree server;

    setUp(() async => server = await FakeInvenTree.start());
    tearDown(() => server.close());

    test("All required roles present", () async {
      final auth = AuthService(store: MemoryCredentialStore());
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.connected);
      expect(auth.info!.roles.missing, isEmpty);
      expect(server.requests, contains("GET /api/user/me/roles/"));
    });

    test("Missing roles are reported (login still succeeds)", () async {
      server.roles = {
        "part": ["view"],
        "stock": ["view"],
      };

      final auth = AuthService(store: MemoryCredentialStore());
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.connected);
      expect(auth.info!.roles.missing, [
        "Stock - change (move reels into the machine)",
        "Stock locations - view (choose locations)",
      ]);
    });

    test("Superuser has every permission", () {
      final roles = UserRoles.fromJson({"roles": {}, "is_superuser": true});
      expect(roles.missing, isEmpty);
      expect(roles.can("anything", "delete"), isTrue);
    });

    test("Roles parsing", () {
      final roles = UserRoles.fromJson({
        "roles": {
          "stock": ["view", "change"],
          "part": null,
        },
      });
      expect(roles.can("stock", "change"), isTrue);
      expect(roles.can("stock", "delete"), isFalse);
      expect(roles.can("part", "view"), isFalse);
    });
  });

  group("Log:", () {
    test("Bounded, filtered export, clear", () {
      final log = AppLog(capacity: 3);
      log.debug("a", "one");
      log.info("a", "two");
      log.warning("b", "three");
      log.error("b", "four");

      expect(log.length, 3);
      expect(log.entries.first.message, "two");
      expect(log.errorCount, 1);

      final String errors = log.export(minLevel: LogLevel.error);
      expect(errors, contains("four"));
      expect(errors, isNot(contains("three")));

      log.clear();
      expect(log.length, 0);
    });

    test("Snippets hide control characters and truncate", () {
      expect(logSnippet("a\u001Db\nc"), "a·b·c");
      expect(logSnippet("x" * 100, max: 10), startsWith("xxxxxxxxxx..."));
    });

    test(
      "Login is logged, but never the password, cookies or CSRF token",
      () async {
        final server = await FakeInvenTree.start();
        addTearDown(server.close);
        appLog.clear();

        final store = MemoryCredentialStore();
        final auth = AuthService(store: store);
        await auth.login(server.url, "reader", "secret");
        await auth.api.get("user/me/");
        await auth.logout();
        await auth.login(server.url, "reader", "wrong-password");

        final String text = appLog.export();
        expect(text, contains("Login: reader"));
        expect(text, contains("Connected to"));
        expect(text, contains("GET /api/user/me/"));

        expect(text, isNot(contains("secret")));
        expect(text, isNot(contains("wrong-password")));
        for (final id in [
          ...server.sessions.keys,
          "sess0",
          "sess1",
          "csrf0",
          "csrf1",
        ]) {
          expect(text, isNot(contains(id)), reason: id);
        }
        expect(text, isNot(contains(SESSION_COOKIE_NAME)));
        expect(text, isNot(contains(CSRF_COOKIE_NAME)));
      },
    );
  });

  group("Preferences:", () {
    test("Defaults, persistence, and kept when the server changes", () async {
      final backend = MemorySettingsBackend();
      final store = SettingsStore(backend);

      await store.load("https://a.example.com/");
      expect(store.prefs.autoReturn, isTrue);
      expect(store.prefs.keepScreenOn, isTrue);

      await store.save(
        const WorkflowSettings(
          source: StockLocationInfo(pk: 1, name: "S", pathstring: "S"),
          machine: StockLocationInfo(pk: 2, name: "M", pathstring: "M"),
        ),
      );
      await store.savePrefs(
        const AppPreferences(autoReturn: false, keepScreenOn: false),
      );

      final again = SettingsStore(backend);
      await again.load("https://a.example.com/");
      expect(again.prefs.autoReturn, isFalse);
      expect(again.prefs.keepScreenOn, isFalse);
      expect(again.settings.isComplete, isTrue);

      // Another server: preferences kept, locations not
      final other = SettingsStore(backend);
      await other.load("https://b.example.com/");
      expect(other.prefs.autoReturn, isFalse);
      expect(other.settings.isComplete, isFalse);
    });

    test("Scanner mode: camera by default, persisted", () async {
      final backend = MemorySettingsBackend();
      final store = SettingsStore(backend);
      await store.load("https://a.example.com/");
      expect(store.prefs.scannerMode, ScannerMode.camera);

      await store.savePrefs(
        store.prefs.copyWith(scannerMode: ScannerMode.dataWedge),
      );
      final again = SettingsStore(backend);
      await again.load("https://a.example.com/");
      expect(again.prefs.scannerMode, ScannerMode.dataWedge);
      expect(again.prefs.autoReturn, isTrue);

      // Unknown stored value - fall back to the camera
      expect(
        AppPreferences.fromJson({"scanner": "laser"}).scannerMode,
        ScannerMode.camera,
      );
    });
  });
}
