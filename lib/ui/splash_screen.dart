import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";

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
              Icon(
                Icons.precision_manufacturing,
                size: 96,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                "SMT Reel Loader",
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(),
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
