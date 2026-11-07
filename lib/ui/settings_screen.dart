import "dart:async";

import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/certificates.dart";
import "package:inventree_smt/core/device.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/log_screen.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";

/// App settings: locations, workflow behaviour, connection, log, about.
/// Changes are saved as soon as they are made.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.repo,
    required this.auth,
    this.workflowActive = false,
    this.device = const DeviceService(),
    this.log,
  });

  final SettingsStore store;
  final InvenTreeRepository repo;
  final AuthService auth;

  /// A reel swap is in progress (changing locations will reset it).
  final bool workflowActive;

  final DeviceService device;

  /// Defaults to the app-wide log.
  final AppLog? log;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _appVersion = "";

  AppLog get _log => widget.log ?? appLog;

  @override
  void initState() {
    super.initState();
    widget.device.appVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    });
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _confirm(String title, String message, String action) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message, style: const TextStyle(fontSize: 17)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("CANCEL"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _pick({required bool machine}) async {
    final StockLocationInfo? picked = await Navigator.of(context)
        .push<StockLocationInfo>(
          MaterialPageRoute(
            builder: (_) => LocationPickerPage(
              repo: widget.repo,
              title: machine ? "Machine location" : "Source location",
              allowStructural: !machine,
            ),
          ),
        );
    if (picked == null || !mounted) return;

    final WorkflowSettings current = widget.store.settings;
    if ((machine ? current.machine?.pk : current.source?.pk) == picked.pk) {
      return;
    }

    final WorkflowSettings next = machine
        ? current.copyWith(machine: picked)
        : current.copyWith(source: picked);

    final String? error = validateLocations(next.source, next.machine);
    if (error != null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.error, color: StatusColors.error, size: 40),
          title: const Text("Location not changed"),
          content: Text(error, style: const TextStyle(fontSize: 17)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
      return;
    }

    if (widget.workflowActive &&
        !await _confirm(
          "Reset the reel swap?",
          "Changing locations resets the reel swap in progress. "
              "Nothing has been transferred yet.",
          "CHANGE",
        )) {
      return;
    }

    try {
      await widget.store.save(next);
      _log.info(
        "settings",
        "${machine ? "Machine" : "Source"} location set to "
            "${picked.pathstring} (#${picked.pk})",
      );
    } catch (_) {
      if (mounted) _snack("Settings could not be saved on this device.");
    }
    if (mounted) setState(() {});
  }

  Future<void> _setPrefs(AppPreferences prefs) async {
    try {
      await widget.store.savePrefs(prefs);
      _log.info("settings", "Preferences: ${prefs.toJson()}");
    } catch (_) {
      if (mounted) _snack("Settings could not be saved on this device.");
    }
    if (mounted) setState(() {});
  }

  Future<void> _forgetCertificate() async {
    if (!await _confirm(
      "Forget the trusted certificate?",
      "The app will ask whether to trust the server's certificate "
          "the next time it connects.",
      "FORGET",
    )) {
      return;
    }
    await widget.auth.forgetTrustedCertificate();
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    if (!await _confirm(
      "Log out?",
      "You will need to enter your password to log in again.",
      "LOG OUT",
    )) {
      return;
    }
    // The app returns to the login screen (closing this screen)
    await widget.auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    final WorkflowSettings locations = widget.store.settings;
    final AppPreferences prefs = widget.store.prefs;
    final ConnectionInfo? info = widget.auth.info;
    final TrustedCertificate? cert = widget.auth.trustedCertificate;

    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const _SectionTitle("Locations"),
            _LocationTile(
              title: "Source location",
              help:
                  "Where replacement reels are taken from (including sub-locations).",
              icon: Icons.inventory_2,
              location: locations.source,
              onTap: () => _pick(machine: false),
            ),
            const SizedBox(height: 12),
            _LocationTile(
              title: "Machine location",
              help: "The SMT machine. Loaded reels are transferred here.",
              icon: Icons.precision_manufacturing,
              location: locations.machine,
              onTap: () => _pick(machine: true),
            ),
            const _SectionTitle("Workflow"),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    key: const Key("pref-auto-return"),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    title: const Text(
                      "Return to start after a transfer",
                      style: TextStyle(fontSize: 18),
                    ),
                    subtitle: const Text(
                      "Go back to step 1 automatically "
                      "${AppPreferences.autoReturnSeconds} seconds after "
                      "a transfer completes.",
                    ),
                    value: prefs.autoReturn,
                    onChanged: (v) => _setPrefs(prefs.copyWith(autoReturn: v)),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key("pref-keep-screen-on"),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    title: const Text(
                      "Keep the screen on during a reel swap",
                      style: TextStyle(fontSize: 18),
                    ),
                    subtitle: const Text(
                      "From the first scan until the transfer is done "
                      "or the swap is reset.",
                    ),
                    value: prefs.keepScreenOn,
                    onChanged: (v) =>
                        _setPrefs(prefs.copyWith(keepScreenOn: v)),
                  ),
                ],
              ),
            ),
            const _SectionTitle("Connection"),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  _InfoTile(
                    icon: Icons.dns,
                    label: "Server",
                    value: info?.server ?? widget.auth.api.server,
                  ),
                  _InfoTile(
                    icon: Icons.person,
                    label: "Logged in as",
                    value: info == null
                        ? "-"
                        : info.fullName.isEmpty
                        ? info.username
                        : "${info.username} (${info.fullName})",
                  ),
                  if (cert != null) ...[
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: const Icon(
                        Icons.verified_user,
                        color: StatusColors.warning,
                        size: 32,
                      ),
                      title: const Text(
                        "Trusted self-signed certificate",
                        style: TextStyle(fontSize: 18),
                      ),
                      subtitle: SelectableText(
                        "SHA-256 ${cert.fingerprint}",
                        style: const TextStyle(
                          fontFamily: "monospace",
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: OutlinedButton.icon(
                        onPressed: _forgetCertificate,
                        icon: const Icon(Icons.remove_moderator),
                        label: const Text("FORGET CERTIFICATE"),
                      ),
                    ),
                  ],
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton.icon(
                      key: const Key("settings-logout"),
                      onPressed: widget.auth.busy ? null : _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("LOG OUT"),
                    ),
                  ),
                ],
              ),
            ),
            const _SectionTitle("Diagnostics"),
            Card(
              margin: EdgeInsets.zero,
              child: ListenableBuilder(
                listenable: _log,
                builder: (context, _) => ListTile(
                  key: const Key("settings-view-log"),
                  minTileHeight: 72,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.receipt_long, size: 32),
                  title: const Text("View log", style: TextStyle(fontSize: 18)),
                  subtitle: Text(
                    "${_log.length} entries since the app was started"
                    "${_log.errorCount == 0 ? "" : "  ·  ${_log.errorCount} errors"}",
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 32),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => LogScreen(log: _log)),
                  ),
                ),
              ),
            ),
            const _SectionTitle("About"),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  _InfoTile(
                    icon: Icons.phone_android,
                    label: "App version",
                    value: _appVersion.isEmpty ? "-" : _appVersion,
                  ),
                  _InfoTile(
                    icon: Icons.storage,
                    label: "InvenTree server",
                    value: info == null
                        ? "-"
                        : "${info.serverVersion} (API ${info.apiVersion})"
                              "${info.instanceName.isEmpty ? "" : "  ·  ${info.instanceName}"}",
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: Icon(icon, size: 28),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
    subtitle: SelectableText(value, style: const TextStyle(fontSize: 18)),
  );
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    required this.title,
    required this.help,
    required this.icon,
    required this.location,
    required this.onTap,
  });

  final String title;
  final String help;
  final IconData icon;
  final StockLocationInfo? location;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    location?.pathstring ?? "Not set - tap to choose",
                    style: TextStyle(
                      fontSize: 18,
                      color: location == null ? StatusColors.error : null,
                      fontWeight: location == null
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    help,
                    style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 32),
          ],
        ),
      ),
    ),
  );
}

/// Search for and choose a stock location.
class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({
    super.key,
    required this.repo,
    required this.title,
    required this.allowStructural,
  });

  final InvenTreeRepository repo;
  final String title;
  final bool allowStructural;

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  List<StockLocationInfo> _results = [];
  String? _error;
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _load() async {
    final int request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await widget.repo.searchLocations(_search.text);
      if (!mounted || request != _request) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _search,
              onChanged: _onChanged,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: "Search locations",
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: StatusPanel(
                kind: StatusKind.error,
                title: "Search failed",
                message: _error!,
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final StockLocationInfo loc = _results[i];
                final bool disabled = loc.structural && !widget.allowStructural;
                return ListTile(
                  minTileHeight: 64,
                  enabled: !disabled,
                  leading: Icon(
                    loc.structural ? Icons.account_tree : Icons.place,
                    size: 32,
                  ),
                  title: Text(
                    loc.pathstring,
                    style: const TextStyle(fontSize: 18),
                  ),
                  subtitle: disabled
                      ? const Text("Structural - stock cannot be placed here")
                      : null,
                  onTap: disabled ? null : () => Navigator.of(context).pop(loc),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
