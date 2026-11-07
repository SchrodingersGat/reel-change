/*
 * Self-signed certificate trust, against an HTTPS fake InvenTree server.
 *
 * Test certificates are generated with openssl into a temporary directory at
 * test time (no key material is kept in the repository). The tests are
 * skipped if openssl is not available.
 */

import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/auth/session_store.dart";
import "package:inventree_smt/core/certificates.dart";
import "package:inventree_smt/core/credential_store.dart";

import "fake_inventree.dart";

class _TestCert {
  _TestCert(this.cert, this.key, this.fingerprint);

  final String cert;
  final String key;

  /// SHA-256 fingerprint as reported by openssl
  final String fingerprint;

  SecurityContext get context => SecurityContext()
    ..useCertificateChain(cert)
    ..usePrivateKey(key);

  List<int> get der {
    // PEM -> DER
    final String body = File(
      cert,
    ).readAsLinesSync().where((l) => !l.startsWith("-----")).join();
    return base64.decode(body);
  }
}

Future<_TestCert?> _makeCert(Directory dir, String name) async {
  // Stop MSYS (Git for Windows) rewriting "/CN=..." as a path
  final env = {"MSYS_NO_PATHCONV": "1"};
  final String cert = "${dir.path}/$name.pem";
  final String key = "${dir.path}/$name.key";

  try {
    final r = await Process.run("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes", //
      "-keyout", key, "-out", cert, "-days", "2",
      "-subj", "/CN=SMT test $name",
      "-addext", "subjectAltName=IP:127.0.0.1",
    ], environment: env);
    if (r.exitCode != 0) return null;

    final f = await Process.run("openssl", [
      "x509",
      "-in",
      cert,
      "-noout",
      "-fingerprint",
      "-sha256",
    ], environment: env);
    if (f.exitCode != 0) return null;

    final String fp = (f.stdout as String).trim().split("=").last.toUpperCase();
    return _TestCert(cert, key, fp);
  } on ProcessException {
    return null;
  }
}

void main() {
  Directory? dir;
  _TestCert? certA;
  _TestCert? certB;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp("smt_cert_test");
    certA = await _makeCert(dir!, "a");
    certB = await _makeCert(dir!, "b");
  });

  tearDownAll(() async {
    await dir?.delete(recursive: true);
  });

  bool skip() {
    if (certA == null || certB == null) {
      markTestSkipped("openssl not available");
      return true;
    }
    return false;
  }

  late FakeInvenTree server;
  late MemoryCredentialStore store;

  Future<void> startServer(_TestCert cert) async {
    server = await FakeInvenTree.start(tls: cert.context);
    store = MemoryCredentialStore();
  }

  tearDown(() async {
    try {
      await server.close();
    } catch (_) {}
  });

  test("Fingerprint matches openssl", () {
    if (skip()) return;
    expect(sha256Fingerprint(certA!.der), certA!.fingerprint);
  });

  test(
    "Untrusted certificate: login stops before the password is sent",
    () async {
      if (skip()) return;
      await startServer(certA!);

      final auth = AuthService(store: store);
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.pendingCertificate, isNotNull);
      expect(auth.certificateChanged, isFalse);
      expect(auth.pendingCertificate!.fingerprint, certA!.fingerprint);
      expect(auth.pendingCertificate!.subject, contains("SMT test a"));
      expect(auth.message, contains("not trusted"));

      // Nothing reached the server - in particular, not the password
      expect(server.requests, isEmpty);
      expect(server.loginBodies, isEmpty);
      expect(store.trustedCertificate, isNull);
    },
  );

  test("Trust, log in, then auto-login with the pinned certificate", () async {
    if (skip()) return;
    await startServer(certA!);

    final auth = AuthService(store: store);
    await auth.login(server.url, "reader", "secret");
    expect(await auth.trustPendingCertificate(), isTrue);

    final TrustedCertificate stored = TrustedCertificate.fromJson(
      store.trustedCertificate,
    )!;
    expect(stored.fingerprint, certA!.fingerprint);
    expect(stored.origin, serverOrigin(server.url));

    await auth.login(server.url, "reader", "secret");
    expect(auth.phase, AuthPhase.connected, reason: auth.message);

    // Next launch
    final relaunch = AuthService(store: store);
    await relaunch.restore();
    expect(relaunch.phase, AuthPhase.connected, reason: relaunch.message);
    expect(relaunch.trustedCertificate?.fingerprint, certA!.fingerprint);
  });

  test(
    "A different certificate is not accepted, and is reported as CHANGED",
    () async {
      if (skip()) return;
      await startServer(certA!);

      // The user previously trusted certificate B for this server
      store.trustedCertificate = TrustedCertificate(
        origin: serverOrigin(server.url),
        der: Uint8List.fromList(certB!.der),
      ).toJson();

      final auth = AuthService(store: store);
      await auth.login(server.url, "reader", "secret");

      expect(auth.phase, AuthPhase.loggedOut);
      expect(auth.certificateChanged, isTrue);
      expect(auth.message, contains("CHANGED"));
      expect(auth.pendingCertificate!.fingerprint, certA!.fingerprint);
      expect(server.loginBodies, isEmpty);
    },
  );

  test("Trust is only applied to the server it was given for", () async {
    if (skip()) return;
    await startServer(certA!);

    store.trustedCertificate = TrustedCertificate(
      origin: "https://some-other-server:443",
      der: Uint8List.fromList(certA!.der),
    ).toJson();

    final auth = AuthService(store: store);
    await auth.login(server.url, "reader", "secret");

    expect(auth.phase, AuthPhase.loggedOut);
    expect(auth.pendingCertificate, isNotNull);
    expect(auth.certificateChanged, isFalse);
  });

  test("Rejecting and forgetting", () async {
    if (skip()) return;
    await startServer(certA!);

    final auth = AuthService(store: store);
    await auth.login(server.url, "reader", "secret");
    auth.rejectPendingCertificate();
    expect(auth.pendingCertificate, isNull);
    expect(store.trustedCertificate, isNull);

    await auth.login(server.url, "reader", "secret");
    await auth.trustPendingCertificate();
    await auth.login(server.url, "reader", "secret");
    expect(auth.phase, AuthPhase.connected);

    await auth.forgetTrustedCertificate();
    expect(store.trustedCertificate, isNull);
    expect(auth.trustedCertificate, isNull);

    final relaunch = AuthService(store: store);
    await relaunch.restore();
    expect(relaunch.phase, AuthPhase.loggedOut);
    expect(relaunch.pendingCertificate, isNotNull);
  });
}
