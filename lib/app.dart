import "package:flutter/material.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/core/settings_store.dart";
import "package:reel_change/ui/home_screen.dart";
import "package:reel_change/ui/login_screen.dart";
import "package:reel_change/ui/splash_screen.dart";
import "package:reel_change/ui/theme.dart";

class SmtApp extends StatefulWidget {
  const SmtApp({super.key, required this.auth, required this.settings});

  final AuthService auth;
  final SettingsStore settings;

  @override
  State<SmtApp> createState() => _SmtAppState();
}

class _SmtAppState extends State<SmtApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  AuthPhase _lastPhase = AuthPhase.starting;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// When the session ends (logout, expiry), close any screens opened on top of
  /// the home screen (settings, log, scanner, dialogs) so the login screen is shown.
  void _onAuthChanged() {
    final AuthPhase phase = widget.auth.phase;
    if (_lastPhase == AuthPhase.connected && phase != AuthPhase.connected) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    _lastPhase = phase;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Reel Change",
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // The screen shown is driven entirely by the authentication state:
      // launching / not logged in / logged in. There is no way to reach the
      // rest of the app without a verified session.
      home: ListenableBuilder(
        listenable: widget.auth,
        builder: (context, _) {
          switch (widget.auth.phase) {
            case AuthPhase.starting:
              return SplashScreen(auth: widget.auth);
            case AuthPhase.loggedOut:
            case AuthPhase.mfaRequired:
              return LoginScreen(auth: widget.auth);
            case AuthPhase.connected:
              return HomeScreen(auth: widget.auth, settings: widget.settings);
          }
        },
      ),
    );
  }
}
