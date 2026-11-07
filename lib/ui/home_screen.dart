import "dart:async";

import "package:flutter/material.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/core/app_log.dart";
import "package:reel_change/core/device.dart";
import "package:reel_change/core/settings_store.dart";
import "package:reel_change/inventree/inventree_repository.dart";
import "package:reel_change/scanner/hardware_scanner.dart";
import "package:reel_change/ui/settings_screen.dart";
import "package:reel_change/ui/theme.dart";
import "package:reel_change/ui/workflow/done_step.dart";
import "package:reel_change/ui/workflow/load_step.dart";
import "package:reel_change/ui/workflow/scan_part_step.dart";
import "package:reel_change/ui/workflow/select_stock_step.dart";
import "package:reel_change/ui/workflow/widgets.dart";
import "package:reel_change/workflow/load_workflow.dart";
import "package:reel_change/workflow/location_check.dart";

/// Main screen once logged in: hosts the reel-loading workflow, one step at a time.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.auth,
    required this.settings,
    this.device = const DeviceService(),
  });

  final AuthService auth;
  final SettingsStore settings;
  final DeviceService device;

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

  // Why stored locations were removed by the startup check (cleared once
  // the locations are set up again)
  List<String> _locationProblems = const [];

  // Current keep-screen-on state requested from the device
  bool _screenKeptOn = false;

  @override
  void initState() {
    super.initState();
    _workflow.addListener(_updateKeepScreenOn);
    widget.settings.addListener(_onSettingsChanged);
    _loadSettings();
  }

  /// Load the stored settings, and check the stored locations still exist
  /// (and are still valid) on the server.
  Future<void> _loadSettings() async {
    try {
      await widget.settings.load(widget.auth.api.server);

      // Make sure the DataWedge profile exists (e.g. after DataWedge was
      // reset, or the app was reinstalled)
      if (widget.settings.prefs.scannerMode == ScannerMode.dataWedge) {
        unawaited(widget.device.configureDataWedge());
      }

      final LocationCheckResult result = await recheckLocations(
        widget.settings,
        _repo,
      );
      if (mounted) setState(() => _locationProblems = result.problems);
    } catch (e) {
      appLog.error("settings", "Could not load settings: $e");
    }
    if (mounted) setState(() => _settingsLoaded = true);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _workflow.removeListener(_updateKeepScreenOn);
    _workflow.dispose();
    if (_screenKeptOn) widget.device.setKeepScreenOn(false);
    super.dispose();
  }

  /// A reel swap is under way (from the first scan until done or reset).
  bool get _workflowActive =>
      _workflow.canReset && _workflow.step != WorkflowStep.done;

  /// Keep the screen on while a swap is active (if enabled in settings).
  void _updateKeepScreenOn() {
    final bool on = widget.settings.prefs.keepScreenOn && _workflowActive;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    widget.device.setKeepScreenOn(on);
  }

  void _onSettingsChanged() {
    final WorkflowSettings s = widget.settings.settings;
    final bool changed =
        s.source?.pk != _workflow.settings.source?.pk ||
        s.machine?.pk != _workflow.settings.machine?.pk;

    _workflow.settings = s;
    if (changed) _workflow.reset();
    if (s.isComplete) _locationProblems = const [];
    _updateKeepScreenOn();
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
      builder: (_) => SettingsScreen(
        store: widget.settings,
        repo: _repo,
        auth: widget.auth,
        workflowActive: _workflowActive,
        device: widget.device,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ConnectionInfo? info = widget.auth.info;
    // The workflow is available (RESET and progress shown) only when
    // locations are set and the user has the permissions it needs
    final bool configured =
        widget.settings.settings.isComplete &&
        (info?.roles.missing.isEmpty ?? true);

    return ListenableBuilder(
      listenable: _workflow,
      builder: (context, _) => PopScope(
        // Android back: never leave the app mid-workflow by accident
        canPop: !_workflow.canReset,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmReset();
        },
        child: Scaffold(
          // The home screens have no text fields - the keyboard only appears
          // for dialogs (which move themselves above it). Don't squash the
          // workflow behind the dialog when it does.
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            title: const Text("Reel Change"),
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
              IconButton(
                key: const Key("open-settings"),
                tooltip: "Settings",
                iconSize: 30,
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (info != null) LoginStatusBanner(info: info),
                Expanded(
                  child: ScannerScope(
                    mode: widget.settings.prefs.scannerMode,
                    scans: widget.device.hardwareScans,
                    child: _body(),
                  ),
                ),
                if (configured) WorkflowProgressBar(step: _workflow.step),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (!_settingsLoaded) {
      return const StepBusy(message: "Checking settings...");
    }

    final List<String> missing = widget.auth.info?.roles.missing ?? const [];

    if (missing.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          StatusPanel(
            kind: StatusKind.error,
            large: true,
            title: "PERMISSION REQUIRED",
            message:
                "Your InvenTree account (${widget.auth.info!.username}) is missing "
                "permissions needed to load reels:",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in missing)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      "\u2022 $m",
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                const Text(
                  "Ask an InvenTree administrator to add these to your account "
                  "(Admin > Users / Groups), then log in again.",
                  style: TextStyle(fontSize: 17, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (!widget.settings.settings.isComplete) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_locationProblems.isNotEmpty) ...[
              StatusPanel(
                key: const Key("location-problems"),
                kind: StatusKind.error,
                title: "Locations changed in InvenTree",
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final p in _locationProblems)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          "\u2022 $p",
                          style: const TextStyle(
                            fontSize: 17,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
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
      WorkflowStep.done => DoneStep(
        workflow: _workflow,
        autoReturn: widget.settings.prefs.autoReturn,
      ),
    };
  }
}

/// Compact strip at the top of the screen showing who is logged in.
class LoginStatusBanner extends StatelessWidget {
  const LoginStatusBanner({super.key, required this.info});

  final ConnectionInfo info;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: "Logged in as ${info.username}",
      excludeSemantics: true,
      child: Container(
        color: StatusColors.ok,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.person, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                info.username,
                key: const Key("login-status"),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
