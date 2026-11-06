import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/ui/theme.dart";

/// Main screen once logged in. The reel loading workflow will live here.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.auth});

  final AuthService auth;

  Future<void> _confirmLogout(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Log out?"),
        content: const Text(
          "You will need to enter your password to log in again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("CANCEL"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("LOG OUT"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await auth.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ConnectionInfo? info = auth.info;

    return Scaffold(
      appBar: AppBar(
        title: const Text("SMT Reel Loader"),
        actions: [
          IconButton(
            tooltip: "Log out",
            icon: const Icon(Icons.logout),
            onPressed: auth.busy ? null : () => _confirmLogout(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (info != null) LoginStatusBanner(info: info),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    "Reel loading workflow coming next.",
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact strip at the top of the screen showing who is logged in, and where.
class LoginStatusBanner extends StatelessWidget {
  const LoginStatusBanner({super.key, required this.info});

  final ConnectionInfo info;

  @override
  Widget build(BuildContext context) {
    final String version = info.serverVersion.isEmpty
        ? ""
        : "  ·  InvenTree ${info.serverVersion}";

    return Container(
      color: StatusColors.ok,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Logged in as ${info.username}",
                  key: const Key("login-status-user"),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  "${info.serverLabel}$version",
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
