import "dart:async";

import "package:flutter/material.dart";

import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";

/// Choose the source (stores) and machine stock locations.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store, required this.repo});

  final SettingsStore store;
  final InvenTreeRepository repo;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late StockLocationInfo? _source = widget.store.settings.source;
  late StockLocationInfo? _machine = widget.store.settings.machine;

  bool _saving = false;

  String? get _error => validateLocations(_source, _machine);

  bool get _changed =>
      _source?.pk != widget.store.settings.source?.pk ||
      _machine?.pk != widget.store.settings.machine?.pk;

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
    if (picked == null) return;
    setState(() => machine ? _machine = picked : _source = picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.store.save(
        WorkflowSettings(source: _source, machine: _machine),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Settings could not be saved on this device."),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text("Locations")),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _LocationTile(
                    title: "Source location",
                    help:
                        "Where replacement reels are taken from (including sub-locations).",
                    icon: Icons.inventory_2,
                    location: _source,
                    onTap: () => _pick(machine: false),
                  ),
                  const SizedBox(height: 16),
                  _LocationTile(
                    title: "Machine location",
                    help: "The SMT machine. Loaded reels are transferred here.",
                    icon: Icons.precision_manufacturing,
                    location: _machine,
                    onTap: () => _pick(machine: true),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    StatusPanel(
                      kind: StatusKind.error,
                      title: "Invalid locations",
                      message: error,
                    ),
                  ],
                  if (_changed && widget.store.settings.isComplete) ...[
                    const SizedBox(height: 16),
                    const StatusPanel(
                      kind: StatusKind.warning,
                      title: "Workflow will reset",
                      message:
                          "Saving changed locations resets any reel swap in progress.",
                    ),
                  ],
                ],
              ),
            ),
            StepActions(
              children: [
                BigActionButton(
                  label: "SAVE",
                  icon: Icons.save,
                  busy: _saving,
                  onPressed:
                      (_source == null ||
                          _machine == null ||
                          error != null ||
                          !_changed)
                      ? null
                      : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
