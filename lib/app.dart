import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/ui/home_screen.dart";
import "package:inventree_smt/ui/login_screen.dart";
import "package:inventree_smt/ui/splash_screen.dart";
import "package:inventree_smt/ui/theme.dart";

class SmtApp extends StatelessWidget {
  const SmtApp({super.key, required this.auth, required this.settings});

  final AuthService auth;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "SMT Reel Loader",
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // The screen shown is driven entirely by the authentication state:
      // launching / not logged in / logged in. There is no way to reach the
      // rest of the app without a verified session.
      home: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          switch (auth.phase) {
            case AuthPhase.starting:
              return SplashScreen(auth: auth);
            case AuthPhase.loggedOut:
            case AuthPhase.mfaRequired:
              return LoginScreen(auth: auth);
            case AuthPhase.connected:
              return HomeScreen(auth: auth, settings: settings);
          }
        },
      ),
    );
  }
}
