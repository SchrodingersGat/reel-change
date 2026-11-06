import "dart:convert";
import "dart:io";

import "fake_inventory.dart";

/// A minimal fake InvenTree server, implementing just enough of the REST and
/// allauth headless APIs to exercise the login flow. Runs on localhost.
class FakeInvenTree {
  FakeInvenTree._(this._server);

  static Future<FakeInvenTree> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeInvenTree._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;

  String get url => "http://127.0.0.1:${_server.port}/";

  // Accounts: username -> password
  final Map<String, String> users = {"reader": "secret"};

  // Users which require a TOTP code ("123456")
  final Set<String> mfaUsers = {};

  int apiVersion = 571;

  final FakeInventory inventory = FakeInventory();

  // Session id -> username (authenticated), or "?pending:<user>" during MFA
  final Map<String, String> sessions = {};

  // Requests received, as "METHOD /path"
  final List<String> requests = [];

  // Raw request bodies of login POSTs
  final List<String> loginBodies = [];

  // Unsafe requests rejected for a missing / bad CSRF token
  int csrfFailures = 0;

  int _counter = 0;

  Future<void> close() => _server.close(force: true);

  /// Expire all sessions on the "server" (e.g. logged out from the web UI).
  void expireAllSessions() => sessions.clear();

  String? _cookie(HttpRequest request, String name) {
    for (final c in request.cookies) {
      if (c.name == name) return c.value;
    }
    return null;
  }

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    final String method = request.method;
    requests.add("$method $path");

    final String body = await utf8.decoder.bind(request).join();
    final HttpResponse response = request.response;
    response.headers.contentType = ContentType.json;

    // Always (re)issue a CSRF cookie, as Django does for these views
    String csrf = _cookie(request, "csrftoken") ?? "";
    if (csrf.isEmpty) {
      csrf = "csrf${_counter++}";
      response.cookies.add(Cookie("csrftoken", csrf)..path = "/");
    }

    final String? sessionId = _cookie(request, "sessionid");
    final String? sessionUser = sessionId == null ? null : sessions[sessionId];
    final bool authenticated =
        sessionUser != null && !sessionUser.startsWith("?pending:");

    void send(int status, Object data) {
      response.statusCode = status;
      response.write(json.encode(data));
    }

    void newSession(String value) {
      final String id = "sess${_counter++}";
      sessions[id] = value;
      response.cookies.add(
        Cookie("sessionid", id)
          ..path = "/"
          ..httpOnly = true,
      );
    }

    final bool unsafe = method != "GET";
    if (unsafe &&
        (request.headers.value("X-CSRFToken") != csrf || csrf.isEmpty)) {
      csrfFailures++;
      send(403, {"detail": "CSRF Failed"});
      await response.close();
      return;
    }

    switch ("$method $path") {
      case "GET /api/":
        send(200, {
          "server": "InvenTree",
          "version": "1.8.0 test",
          "instance": "Fake",
          "apiVersion": apiVersion,
        });

      case "GET /api/auth/v1/config":
        send(200, {
          "data": {
            "account": {
              "login_methods": ["username"],
            },
          },
        });

      case "GET /api/auth/v1/auth/session":
        if (authenticated) {
          send(200, {
            "meta": {"is_authenticated": true},
          });
        } else {
          send(401, {
            "data": {
              "flows": [
                {"id": "login"},
              ],
            },
            "meta": {"is_authenticated": false},
          });
        }

      case "POST /api/auth/v1/auth/login":
        loginBodies.add(body);
        final Map<String, dynamic> data =
            json.decode(body) as Map<String, dynamic>;
        final String user = (data["username"] ?? "").toString();

        if (authenticated) {
          send(409, {
            "errors": [
              {"message": "Already authenticated"},
            ],
          });
        } else if (users[user] == null || users[user] != data["password"]) {
          send(400, {
            "errors": [
              {
                "message":
                    "The username and/or password you specified are not correct.",
              },
            ],
          });
        } else if (mfaUsers.contains(user)) {
          newSession("?pending:$user");
          send(401, {
            "data": {
              "flows": [
                {"id": "login"},
                {
                  "id": "mfa_authenticate",
                  "is_pending": true,
                  "types": ["totp"],
                },
              ],
            },
            "meta": {"is_authenticated": false},
          });
        } else {
          newSession(user);
          send(200, {
            "meta": {"is_authenticated": true},
          });
        }

      case "POST /api/auth/v1/auth/2fa/authenticate":
        final Map<String, dynamic> data =
            json.decode(body) as Map<String, dynamic>;
        if (sessionUser == null || !sessionUser.startsWith("?pending:")) {
          send(409, {
            "errors": [
              {"message": "No pending flow"},
            ],
          });
        } else if (data["code"] != "123456") {
          send(400, {
            "errors": [
              {"message": "Incorrect code."},
            ],
          });
        } else {
          sessions.remove(sessionId);
          newSession(sessionUser.substring("?pending:".length));
          send(200, {
            "meta": {"is_authenticated": true},
          });
        }

      case "DELETE /api/auth/v1/auth/session":
        if (sessionId != null) sessions.remove(sessionId);
        send(401, {
          "meta": {"is_authenticated": false},
        });

      case "GET /api/user/me/":
        if (authenticated) {
          send(200, {
            "pk": 1,
            "username": sessionUser,
            "first_name": "Test",
            "last_name": "User",
          });
        } else {
          send(401, {
            "detail": "Authentication credentials were not provided.",
          });
        }

      default:
        if (!authenticated) {
          send(401, {
            "detail": "Authentication credentials were not provided.",
          });
        } else {
          final result = inventory.handle(method, request.uri, body);
          if (result == null) {
            send(404, {"detail": "Not found"});
          } else {
            send(result.$1, result.$2);
          }
        }
    }

    await response.close();
  }
}
