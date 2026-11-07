import "dart:async";

import "package:flutter/material.dart";

import "package:reel_change/core/settings_store.dart";
import "package:reel_change/inventree/inventree_repository.dart";

/// The scanner choice for the screens below it (set by the home screen from
/// the settings). Without a scope, the camera is used.
class ScannerScope extends InheritedWidget {
  const ScannerScope({
    super.key,
    required this.mode,
    required this.scans,
    required super.child,
  });

  final ScannerMode mode;

  /// Hardware scanner barcodes (only used in [ScannerMode.dataWedge]).
  final Stream<String> scans;

  bool get hardware => mode == ScannerMode.dataWedge;

  static ScannerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScannerScope>();

  @override
  bool updateShouldNotify(ScannerScope oldWidget) =>
      mode != oldWidget.mode || scans != oldWidget.scans;
}

/// A usable barcode from a hardware scan, or null (empty or too long).
String? acceptScan(String raw) {
  final String value = raw.trim();
  if (value.isEmpty || value.length > kMaxBarcodeLength) return null;
  return value;
}

/// Calls [onScan] when the hardware scanner trigger is used while this
/// screen is showing (not covered by a dialog or another page) and
/// [enabled]. Does nothing unless the scanner is set to DataWedge.
class HardwareScanListener extends StatefulWidget {
  const HardwareScanListener({
    super.key,
    required this.onScan,
    required this.child,
    this.enabled = true,
  });

  final void Function(String barcode) onScan;
  final bool enabled;
  final Widget child;

  @override
  State<HardwareScanListener> createState() => _HardwareScanListenerState();
}

class _HardwareScanListenerState extends State<HardwareScanListener> {
  StreamSubscription<String>? _sub;
  Stream<String>? _stream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final ScannerScope? scope = ScannerScope.maybeOf(context);
    final Stream<String>? stream = scope != null && scope.hardware
        ? scope.scans
        : null;

    if (stream == _stream) return;
    _sub?.cancel();
    _stream = stream;
    _sub = stream?.listen(_onScan);
  }

  void _onScan(String raw) {
    if (!mounted || !widget.enabled) return;
    // Ignore scans while a dialog or another page is on top
    if (ModalRoute.of(context)?.isCurrent == false) return;

    final String? value = acceptScan(raw);
    if (value != null) widget.onScan(value);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Full-screen "press the trigger" page for the hardware scanner. Returns the
/// scanned (or typed) barcode, or null if cancelled.
class TriggerScanPage extends StatefulWidget {
  const TriggerScanPage({
    super.key,
    required this.title,
    required this.scans,
    required this.typeBarcode,
  });

  final String title;
  final Stream<String> scans;

  /// Opens the manual entry dialog.
  final Future<String?> Function(BuildContext context) typeBarcode;

  @override
  State<TriggerScanPage> createState() => _TriggerScanPageState();
}

class _TriggerScanPageState extends State<TriggerScanPage> {
  late final StreamSubscription<String> _sub;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.scans.listen(_onScan);
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  void _finish(String? value) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(value);
  }

  void _onScan(String raw) {
    // Not while the manual entry dialog is open
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    final String? value = acceptScan(raw);
    if (value != null) _finish(value);
  }

  Future<void> _manual() async {
    final String? value = await widget.typeBarcode(context);
    if (value != null) _finish(value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.qr_code_scanner,
                          size: 120,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          "Press the scanner trigger",
                          key: const Key("trigger-scan-prompt"),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          "Aim the device's scanner at the barcode.",
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 32),
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _manual,
                icon: const Icon(Icons.keyboard),
                label: const Text("TYPE BARCODE"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
