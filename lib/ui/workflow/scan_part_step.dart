import "package:flutter/material.dart";

import "package:reel_change/inventree/inventree_repository.dart";
import "package:reel_change/scanner/scanner_page.dart";
import "package:reel_change/ui/theme.dart";
import "package:reel_change/ui/workflow/widgets.dart";
import "package:reel_change/workflow/load_workflow.dart";

/// Step 1: scan the empty reel, and confirm the part against the SMT machine.
class ScanPartStep extends StatelessWidget {
  const ScanPartStep({super.key, required this.workflow, required this.server});

  final LoadWorkflow workflow;
  final String server;

  static const String _scanTitle = "Scan the empty reel";

  Future<void> _scan(BuildContext context) async {
    final String? barcode = await scanBarcode(context, title: _scanTitle);
    if (barcode != null) await workflow.scanPart(barcode);
  }

  Future<void> _type(BuildContext context) async {
    final String? barcode = await enterBarcodeManually(
      context,
      title: _scanTitle,
    );
    if (barcode != null) await workflow.scanPart(barcode);
  }

  @override
  Widget build(BuildContext context) {
    if (workflow.busy) {
      return StepLayout(
        title: "Scan Empty Reel",
        body: StepBusy(message: workflow.busyMessage),
      );
    }

    final ScanOutcome? scan = workflow.partScan;

    if (scan == null) return _start(context);

    final rescan = OutlinedButton.icon(
      onPressed: () {
        workflow.clearPartScan();
        _scan(context);
      },
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text("SCAN AGAIN"),
    );

    switch (scan) {
      case ScanResolved():
      case ScanAmbiguous() when workflow.expected != null:
        return StepLayout(
          title: "Check Part",
          instruction:
              "Confirm this MPN matches the part the SMT machine is asking for on this feeder.",
          body: StepContent(
            children: [PartSummaryCard(part: workflow.expected!)],
          ),
          actions: [
            BigActionButton(
              label: "CONFIRM PART",
              icon: Icons.check,
              color: StatusColors.ok,
              onPressed: workflow.confirmPart,
            ),
            rescan,
          ],
        );

      case ScanAmbiguous(:final options):
        return StepLayout(
          title: "Choose Manufacturer",
          instruction:
              "MPN ${options.first.manufacturerPart.mpn} is listed for more than one "
              "manufacturer. Choose the one shown on the reel label.",
          body: StepContent(
            children: [
              for (final option in options)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(
                      option.manufacturerPart.manufacturerName.isEmpty
                          ? "(no manufacturer)"
                          : option.manufacturerPart.manufacturerName,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      option.part.displayName,
                      style: const TextStyle(fontSize: 16),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 32),
                    onTap: () => workflow.chooseExpected(option),
                  ),
                ),
            ],
          ),
          actions: [rescan],
        );

      case ScanDataError(:final issue):
        return StepLayout(
          title: "Fix Data in InvenTree",
          instruction:
              "This part cannot be used until its record is fixed. Fix it, then scan again.",
          body: StepContent(
            children: [DataIssuePanel(issue: issue, server: server)],
          ),
          actions: [
            BigActionButton(
              label: "SCAN AGAIN",
              icon: Icons.qr_code_scanner,
              onPressed: () {
                workflow.clearPartScan();
                _scan(context);
              },
            ),
          ],
        );

      case ScanNotFound(:final message):
        return StepLayout(
          title: "Scan Again",
          instruction: "The barcode was not recognised.",
          body: StepContent(
            children: [
              StatusPanel(
                kind: StatusKind.error,
                large: true,
                title: "NOT FOUND",
                message: message,
              ),
            ],
          ),
          actions: [rescan],
        );

      case ScanFailed(:final message):
        return StepLayout(
          title: "Scan Again",
          instruction: "The barcode could not be looked up.",
          body: StepContent(
            children: [
              StatusPanel(
                kind: StatusKind.error,
                large: true,
                title: "LOOKUP FAILED",
                message: message,
              ),
            ],
          ),
          actions: [rescan],
        );
    }
  }

  // Scrolls on small screens or with large system font sizes rather than
  // overflowing.
  Widget _start(BuildContext context) => StepLayout(
    title: "Scan Empty Reel",
    instruction: "The reel the SMT machine has run out of.",
    body: StepContent(
      children: [
        const SizedBox(height: 16),
        BigActionButton(
          label: "SCAN PART",
          icon: Icons.qr_code_scanner,
          height: 140,
          onPressed: () => _scan(context),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _type(context),
          icon: const Icon(Icons.keyboard),
          label: const Text("TYPE BARCODE OR MPN"),
        ),
      ],
    ),
  );
}
