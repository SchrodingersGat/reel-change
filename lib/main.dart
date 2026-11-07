import "dart:ui";

import "package:flutter/material.dart";

import "package:inventree_smt/app.dart";
import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/credential_store.dart";
import "package:inventree_smt/core/settings_store.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Unhandled errors go to the in-app log (Settings > View log)
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    appLog.error("flutter", details.exceptionAsString());
    defaultOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    appLog.error("app", "Unhandled error: $error");
    return false;
  };

  appLog.info("app", "App started");

  final auth = AuthService(store: SecureCredentialStore());

  final settings = SettingsStore(SecureSettingsBackend());

  runApp(SmtApp(auth: auth, settings: settings));

  // Check for a stored session (auto-login)
  auth.restore();
}
