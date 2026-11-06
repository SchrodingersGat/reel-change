import "package:flutter/material.dart";

import "package:inventree_smt/app.dart";
import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/credential_store.dart";
import "package:inventree_smt/core/settings_store.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService(store: SecureCredentialStore());

  final settings = SettingsStore(SecureSettingsBackend());

  runApp(SmtApp(auth: auth, settings: settings));

  // Check for a stored session (auto-login)
  auth.restore();
}
