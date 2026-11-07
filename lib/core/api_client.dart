import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart" show listEquals;

import "package:inventree_smt/auth/session_store.dart";
import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/certificates.dart";

/// Why a request could not be completed at the transport level.
enum ApiFailure {
  /// The request completed (check [ApiResponse.statusCode]).
  none,

  /// The server address is not a valid http(s) URL.
  invalidUrl,

  /// The server could not be reached (DNS, refused, offline...).
  network,

  /// The server did not respond in time.
  timeout,

  /// TLS certificate validation failed.
  certificate,

  /// The server sent a redirect. Redirects are never followed, so that
  /// session cookies cannot be forwarded to another host.
  redirect,

  /// Anything else (e.g. malformed response).
  other,
}

/// The result of a single request to the InvenTree server.
class ApiResponse {
  ApiResponse({
    required this.method,
    required this.uri,
    this.statusCode = -1,
    this.data,
    this.failure = ApiFailure.none,
    this.failureDetail = "",
  });

  final String method;
  final Uri? uri;

  /// HTTP status code, or -1 if no response was received.
  int statusCode;

  /// Decoded JSON body (Map, List, or null).
  dynamic data;

  ApiFailure failure;

  /// Technical detail of a transport failure (safe to show: never contains credentials).
  String failureDetail;

  /// A response was received from the server.
  bool get isValid => failure == ApiFailure.none && statusCode > 0;

  bool get isSuccess => isValid && statusCode >= 200 && statusCode < 300;

  Map<String, dynamic> asMap() =>
      data is Map<String, dynamic> ? data as Map<String, dynamic> : {};
}

/// Normalise a user-entered server address.
///
/// - Adds `https://` if no scheme is given (plain HTTP must be typed explicitly)
/// - Only allows http / https, requires a host
/// - Rejects user info, query strings and fragments
/// - Always ends with a single `/` (sub-path installs are supported)
///
/// Returns null if the address is not usable.
String? normaliseServerUrl(String input) {
  String value = input.trim();

  if (value.isEmpty) return null;

  if (!value.contains("://")) {
    value = "https://$value";
  }

  final Uri? uri = Uri.tryParse(value);

  if (uri == null) return null;

  final String scheme = uri.scheme.toLowerCase();

  if (scheme != "http" && scheme != "https") return null;
  if (uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;

  String path = uri.path;

  if (!path.endsWith("/")) path = "$path/";

  return uri.replace(scheme: scheme, path: path).toString();
}

/// True if the address is plain HTTP to something other than this device.
bool isInsecureRemote(String server) {
  final Uri? uri = Uri.tryParse(server);

  if (uri == null || uri.scheme != "http") return false;

  final String host = uri.host.toLowerCase();

  return host != "localhost" && host != "127.0.0.1" && host != "::1";
}

/// Minimal client for the InvenTree REST API, using session (cookie) authentication.
///
/// Request handling follows the official InvenTree app (lib/api.dart):
/// - cookies are captured into, and sent from, a [SessionStore] bound to the server origin
/// - unsafe methods send `X-CSRFToken`, `Origin` and `Referer`
/// - credentials are only ever attached to requests for the configured server
///
/// Differences from the official app:
/// - TLS certificates are always validated. There is no "ignore bad certificate"
///   mode; a self-signed certificate is only accepted if the user explicitly
///   trusted that exact certificate for this server ([trustedCertificate]).
/// - redirects are never followed
class InvenTreeApi {
  InvenTreeApi({HttpClient? httpClient}) {
    _client = httpClient ?? HttpClient();
    _client.connectionTimeout = const Duration(seconds: 10);
    _client.badCertificateCallback = _onBadCertificate;
  }

  late final HttpClient _client;

  /// Certificate the user has trusted for the configured server (if any).
  TrustedCertificate? trustedCertificate;

  /// The last certificate rejected for the configured server - so the user
  /// can be asked whether to trust it.
  CertificateInfo? lastRejectedCertificate;

  /// Called only when normal validation fails. Accepts the certificate only if
  /// it is exactly the one the user trusted, for exactly this server origin.
  bool _onBadCertificate(X509Certificate cert, String host, int port) {
    final Uri? server = Uri.tryParse(_server);
    final bool isServer =
        server != null &&
        server.scheme == "https" &&
        server.host.toLowerCase() == host.toLowerCase() &&
        server.port == port;

    if (!isServer) {
      appLog.warning(
        "tls",
        "Rejected invalid certificate from $host:$port (not the configured server)",
      );
      return false;
    }

    final TrustedCertificate? trusted = trustedCertificate;

    if (trusted != null &&
        trusted.origin == serverOrigin(_server) &&
        listEquals(trusted.der, cert.der)) {
      return true;
    }

    final info = CertificateInfo.fromX509(cert, host, port);
    lastRejectedCertificate = info;
    appLog.warning(
      "tls",
      "Rejected certificate from $host:$port - ${trusted == null ? "not trusted" : "DIFFERENT from the trusted certificate"}. "
          "Subject: ${info.subject}; SHA-256 ${info.fingerprint}",
    );
    return false;
  }

  static const Duration _responseTimeout = Duration(seconds: 20);

  static const Set<String> _unsafeMethods = {"POST", "PUT", "PATCH", "DELETE"};

  String _server = "";

  /// Base server URL (normalised, ends with "/"), or empty if not configured.
  String get server => _server;

  SessionStore session = SessionStore();

  /// Called when a (non-auth) API request is rejected with 401,
  /// i.e. the session has expired or was ended on the server.
  void Function()? onUnauthorized;

  /// Point the client at a server, with the session to use for it.
  void configure(String server, SessionStore session) {
    if (server != _server) lastRejectedCertificate = null;
    _server = server;
    this.session = session;
  }

  /// Resolve an API endpoint (relative to `<server>/api/`).
  Uri? apiUri(String endpoint, {Map<String, String>? query}) {
    if (_server.isEmpty) return null;

    final Uri base = Uri.parse(_server).resolve("api/");
    Uri uri = base.resolve(endpoint);

    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParametersAll, ...query});
    }

    return uri;
  }

  Future<ApiResponse> get(String endpoint, {Map<String, String>? query}) =>
      _request("GET", endpoint, query: query);

  Future<ApiResponse> post(String endpoint, {Map<String, dynamic>? body}) =>
      _request("POST", endpoint, body: body);

  Future<ApiResponse> delete(String endpoint) => _request("DELETE", endpoint);

  Map<String, String> _headers(String method, Uri target) {
    final headers = <String, String>{
      HttpHeaders.acceptHeader: "application/json",
      HttpHeaders.contentTypeHeader: "application/json",
    };

    if (!session.isServerUri(target)) return headers;

    final String cookies = session.cookieHeader(target);

    if (cookies.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = cookies;
    }

    if (_unsafeMethods.contains(method)) {
      if (session.hasCsrfToken) {
        headers["X-CSRFToken"] = session.csrfToken;
      }

      // Django CSRF protection checks the Origin (or Referer, for HTTPS)
      headers["Origin"] = target.origin;
      headers[HttpHeaders.refererHeader] = _server;
    }

    return headers;
  }

  Future<ApiResponse> _request(
    String method,
    String endpoint, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final Uri? uri = apiUri(endpoint, query: query);

    final response = ApiResponse(method: method, uri: uri);

    if (uri == null || uri.host.isEmpty) {
      response.failure = ApiFailure.invalidUrl;
      return response;
    }

    try {
      final HttpClientRequest request = await _client.openUrl(method, uri);

      request.followRedirects = false;

      _headers(method, uri).forEach(request.headers.set);

      if (body != null) {
        final List<int> encoded = utf8.encode(json.encode(body));
        request.headers.set(
          HttpHeaders.contentLengthHeader,
          encoded.length.toString(),
        );
        request.add(encoded);
      }

      final HttpClientResponse httpResponse = await request.close().timeout(
        _responseTimeout,
      );

      response.statusCode = httpResponse.statusCode;

      // Store any cookies provided by the server (e.g. session, CSRF token)
      session.captureHeaders(
        uri,
        httpResponse.headers[HttpHeaders.setCookieHeader],
      );

      final String text = await httpResponse
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(_responseTimeout);

      if (httpResponse.isRedirect) {
        response.failure = ApiFailure.redirect;
        response.failureDetail =
            "Server redirected to ${httpResponse.headers.value(HttpHeaders.locationHeader) ?? "?"}";
        return response;
      }

      try {
        response.data = text.isEmpty ? null : json.decode(text);
      } on FormatException {
        // Not JSON (e.g. an HTML error page from a proxy)
        response.data = null;
      }

      _log(
        response.statusCode >= 400 ? LogLevel.warning : LogLevel.debug,
        "$method ${uri.path} -> ${response.statusCode}",
      );

      if (response.statusCode == 401 &&
          !uri.path.contains("/api/auth/") &&
          session.isServerUri(uri)) {
        onUnauthorized?.call();
      }
    } on TimeoutException {
      response.failure = ApiFailure.timeout;
      response.failureDetail = "No response from server";
    } on HandshakeException catch (e) {
      response.failure = ApiFailure.certificate;
      response.failureDetail = e.message;
    } on CertificateException catch (e) {
      response.failure = ApiFailure.certificate;
      response.failureDetail = e.message;
    } on SocketException catch (e) {
      response.failure = ApiFailure.network;
      response.failureDetail = e.osError?.message ?? e.message;
    } on HttpException catch (e) {
      response.failure = ApiFailure.network;
      response.failureDetail = e.message;
    } catch (e) {
      response.failure = ApiFailure.other;
      response.failureDetail = e.runtimeType.toString();
    }

    if (response.failure != ApiFailure.none) {
      _log(
        LogLevel.error,
        "$method ${uri.path} failed: ${response.failure.name}"
        "${response.failureDetail.isEmpty ? "" : " (${response.failureDetail})"}",
      );
    }

    return response;
  }

  // Only method, path and status are logged - never headers (cookies, CSRF
  // token), bodies (passwords) or query strings
  void _log(LogLevel level, String message) =>
      appLog.add(level, "api", message);

  void close() => _client.close(force: true);
}
