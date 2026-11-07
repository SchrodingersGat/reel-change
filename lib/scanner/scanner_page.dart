import "package:flutter/material.dart";
import "package:mobile_scanner/mobile_scanner.dart";

import "package:reel_change/inventree/inventree_repository.dart";
import "package:reel_change/scanner/eci.dart";
import "package:reel_change/scanner/hardware_scanner.dart";
import "package:reel_change/ui/theme.dart";

/// Open the scanner full-screen: the camera, or a "press the trigger" page
/// when the hardware scanner (DataWedge) is chosen in the settings (see
/// [ScannerScope]). Returns the scanned (or typed) barcode, or null if
/// cancelled.
Future<String?> scanBarcode(BuildContext context, {required String title}) {
  final ScannerScope? scope = ScannerScope.maybeOf(context);

  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => scope != null && scope.hardware
          ? TriggerScanPage(
              title: title,
              scans: scope.scans,
              typeBarcode: (context) =>
                  enterBarcodeManually(context, title: title),
            )
          : ScannerPage(title: title),
    ),
  );
}

/// Ask the user to type a barcode (or MPN). Returns null if cancelled.
Future<String?> enterBarcodeManually(
  BuildContext context, {
  required String title,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ManualEntryDialog(title: title),
  );
}

// The dialog owns its text controller, so it is disposed only once the dialog
// has left the tree (after its exit animation) - not when the result returns.
class _ManualEntryDialog extends StatefulWidget {
  const _ManualEntryDialog({required this.title});

  final String title;

  @override
  State<_ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<_ManualEntryDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String v = _controller.text.trim();
    Navigator.pop(context, v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: kMaxBarcodeLength,
      decoration: const InputDecoration(
        labelText: "Barcode or MPN",
        counterText: "",
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text("CANCEL"),
      ),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
        onPressed: _submit,
        child: const Text("OK"),
      ),
    ],
  );
}

/// Text value of a scanned barcode. For 2D codes, an ECI character-set marker
/// that the scanner left in the data is interpreted (as the official app does).
String scannedValue(Barcode code) {
  final decoded = switch (code.rawDecodedBytes) {
    DecodedBarcodeBytes(:final bytes) => bytes,
    DecodedVisionBarcodeBytes(:final bytes) => bytes,
    null => null,
  };

  switch (code.format) {
    case BarcodeFormat.dataMatrix:
    case BarcodeFormat.qrCode:
    case BarcodeFormat.aztec:
    case BarcodeFormat.pdf417:
      return decodeEciPrefixed(code.rawValue, decoded);
    default:
      return code.rawValue ?? "";
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key, required this.title});

  final String title;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish(String? value) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(value);
  }

  void _onDetect(BarcodeCapture capture) {
    for (final code in capture.barcodes) {
      final String value = scannedValue(code).trim();
      if (value.isNotEmpty && value.length <= kMaxBarcodeLength) {
        _finish(value);
        return;
      }
    }
  }

  Future<void> _manual() async {
    await _controller.stop();
    if (!mounted) return;

    final String? value = await enterBarcodeManually(
      context,
      title: widget.title,
    );

    if (value != null) {
      _finish(value);
    } else if (mounted) {
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (!state.isRunning ||
                  state.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }
              final bool on = state.torchState == TorchState.on;
              return IconButton(
                tooltip: on ? "Torch off" : "Torch on",
                iconSize: 32,
                icon: Icon(on ? Icons.flashlight_off : Icons.flashlight_on),
                onPressed: _controller.toggleTorch,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => _CameraError(error: error),
                overlayBuilder: (context, constraints) => const _ScanFrame(),
              ),
            ),
            Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Point the camera at the barcode",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _manual,
                    icon: const Icon(Icons.keyboard),
                    label: const Text("TYPE BARCODE"),
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

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) => Center(
    child: FractionallySizedBox(
      widthFactor: 0.8,
      heightFactor: 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 3),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
  );
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final String message =
        error.errorCode == MobileScannerErrorCode.permissionDenied
        ? "Camera permission was denied. Allow camera access for this app in Android settings, "
              "or type the barcode instead."
        : "The camera could not be started (${error.errorCode.name}). Type the barcode instead.";

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography,
                color: StatusColors.warning,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
