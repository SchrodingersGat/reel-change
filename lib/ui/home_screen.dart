import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/ui/settings_screen.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/done_step.dart";
import "package:inventree_smt/ui/workflow/load_step.dart";
import "package:inventree_smt/ui/workflow/scan_part_step.dart";
import "package:inventree_smt/ui/workflow/select_stock_step.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

/// Main screen once logged in: hosts the reel-loading workflow, one step at a time.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.auth, required this.settings});

  final AuthService auth;
  final SettingsStore settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final InvenTreeRepository _repo = InvenTreeRepository(widget.auth.api);
  late final LoadWorkflow _workflow = LoadWorkflow(
    repo: _repo,
    settings: widget.settings.settings,
  );

  bool _settingsLoaded = false;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
    widget.settings.load(widget.auth.api.server).whenComplete(() {
      if (mounted) setState(() => _settingsLoaded = true);
    });
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _workflow.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    final WorkflowSettings s = widget.settings.settings;
    final bool changed =
        s.source?.pk != _workflow.settings.source?.pk ||
        s.machine?.pk != _workflow.settings.machine?.pk;

    _workflow.settings = s;
    if (changed) _workflow.reset();
    if (mounted) setState(() {});
  }

  Future<void> _confirmReset() async {
    // Nothing to lose at the start of step 1 - reset straight away
    if (_workflow.step == WorkflowStep.scanPart ||
        _workflow.step == WorkflowStep.done) {
      _workflow.reset();
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Reset?"),
        content: const Text(
          "Start again from step 1. Nothing has been transferred yet.",
          style: TextStyle(fontSize: 17),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("CANCEL"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("RESET"),
          ),
        ],
      ),
    );

    if (ok == true) _workflow.reset();
  }

  Future<void> _openSettings() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsScreen(store: widget.settings, repo: _repo),
    ),
  );

  Future<void> _confirmLogout() async {
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

    if (confirmed == true) await widget.auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    final ConnectionInfo? info = widget.auth.info;
    final bool configured = widget.settings.settings.isComplete;

    return ListenableBuilder(
      listenable: _workflow,
      builder: (context, _) => PopScope(
        // Android back: never leave the app mid-workflow by accident
        canPop: !_workflow.canReset,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmReset();
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text("SMT Reel Loader"),
            actions: [
              if (configured)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: TextButton.icon(
                    key: const Key("reset-workflow"),
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed: _workflow.canReset ? _confirmReset : null,
                    icon: const Icon(Icons.restart_alt, size: 28),
                    label: const Text("RESET"),
                  ),
                ),
              PopupMenuButton<String>(
                iconSize: 28,
                onSelected: (v) =>
                    v == "settings" ? _openSettings() : _confirmLogout(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: "settings",
                    child: ListTile(
                      leading: Icon(Icons.settings),
                      title: Text("Locations"),
                    ),
                  ),
                  PopupMenuItem(
                    value: "logout",
                    child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text("Log out"),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (info != null) LoginStatusBanner(info: info),
                Expanded(child: _body()),
                if (configured) WorkflowProgressBar(step: _workflow.step),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (!_settingsLoaded) return const StepBusy(message: "Loading...");

    if (!widget.settings.settings.isComplete) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const StatusPanel(
              kind: StatusKind.warning,
              large: true,
              title: "Set up locations",
              message:
                  "Choose the source location (where reels are stored) and the machine location "
                  "before loading reels.",
            ),
            const SizedBox(height: 24),
            BigActionButton(
              label: "CONFIGURE LOCATIONS",
              icon: Icons.settings,
              onPressed: _openSettings,
            ),
          ],
        ),
      );
    }

    final String server = widget.auth.api.server;

    return switch (_workflow.step) {
      WorkflowStep.scanPart => ScanPartStep(
        workflow: _workflow,
        server: server,
      ),
      WorkflowStep.selectStock => SelectStockStep(
        workflow: _workflow,
        server: server,
      ),
      WorkflowStep.load => LoadStep(workflow: _workflow),
      WorkflowStep.done => DoneStep(workflow: _workflow),
    };
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: "Logged in as ${info.username}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: "  ·  ${info.serverLabel}$version"),
                ],
              ),
              key: const Key("login-status"),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
