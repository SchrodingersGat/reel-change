import "package:flutter/material.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/ui/spinning_logo.dart";

/// Shown while checking for a stored session on launch.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    final String server = auth.profile?.server ?? "";

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SpinningLogo(
                size: 160,
                imageKey: Key("splash-logo"),
                semanticLabel: "Reel Change logo",
              ),
              const SizedBox(height: 24),
              Text(
                "Reel Change",
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              Text(
                server.isEmpty ? "Starting..." : "Connecting to $server",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
