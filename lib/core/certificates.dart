import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";

/// SHA-256 fingerprint of DER bytes, as colon-separated upper-case hex
/// (the format shown by browsers and `openssl x509 -fingerprint -sha256`).
String sha256Fingerprint(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, "0").toUpperCase())
    .join(":");

/// A server certificate which failed validation (or was trusted by the user).
class CertificateInfo {
  CertificateInfo({
    required this.host,
    required this.port,
    required this.der,
    this.subject = "",
    this.issuer = "",
    this.validFrom,
    this.validTo,
  }) : fingerprint = sha256Fingerprint(der);

  factory CertificateInfo.fromX509(
    X509Certificate cert,
    String host,
    int port,
  ) => CertificateInfo(
    host: host,
    port: port,
    der: Uint8List.fromList(cert.der),
    subject: cert.subject,
    issuer: cert.issuer,
    validFrom: cert.startValidity,
    validTo: cert.endValidity,
  );

  final String host;
  final int port;
  final Uint8List der;
  final String subject;
  final String issuer;
  final DateTime? validFrom;
  final DateTime? validTo;
  final String fingerprint;

  bool get isExpired => validTo != null && validTo!.isBefore(DateTime.now());

  /// Exact (byte-for-byte) match - the pinning check.
  bool sameCertificate(List<int> other) => listEquals(der, other);
}

/// A certificate the user chose to trust for one server origin.
///
/// Pinned to the exact certificate, not just the host: if the server presents
/// any other certificate (e.g. it was renewed - or the connection is being
/// intercepted) the user is asked again.
class TrustedCertificate {
  const TrustedCertificate({required this.origin, required this.der});

  /// Server origin, e.g. "https://inventree.local:443".
  final String origin;
  final Uint8List der;

  String get fingerprint => sha256Fingerprint(der);

  String toJson() => json.encode({"origin": origin, "der": base64.encode(der)});

  static TrustedCertificate? fromJson(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      final Map<String, dynamic> m = json.decode(data) as Map<String, dynamic>;
      return TrustedCertificate(
        origin: m["origin"] as String,
        der: base64.decode(m["der"] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
