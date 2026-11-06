import "package:flutter/material.dart";

import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/scanner/scanner_page.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

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
      return StepBusy(message: workflow.busyMessage);
    }

    final ScanOutcome? scan = workflow.partScan;

    if (scan == null) return _start(context);

    final Widget body;
    final List<Widget> actions;

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
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const StatusPanel(
              kind: StatusKind.info,
              title: "Check against the SMT machine",
              message:
                  "Confirm this MPN matches the part the machine is asking for on this feeder.",
            ),
            const SizedBox(height: 16),
            PartSummaryCard(part: workflow.expected!),
          ],
        );
        actions = [
          BigActionButton(
            label: "CONFIRM PART",
            icon: Icons.check,
            color: StatusColors.ok,
            onPressed: workflow.confirmPart,
          ),
          rescan,
        ];

      case ScanAmbiguous(:final options):
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusPanel(
              kind: StatusKind.warning,
              title: "Several matches",
              message:
                  "MPN ${options.first.manufacturerPart.mpn} is listed for more than one manufacturer. "
                  "Choose the one shown on the reel label.",
            ),
            const SizedBox(height: 16),
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
        );
        actions = [rescan];

      case ScanDataError(:final issue):
        body = DataIssuePanel(issue: issue, server: server);
        actions = [
          BigActionButton(
            label: "SCAN AGAIN",
            icon: Icons.qr_code_scanner,
            onPressed: () {
              workflow.clearPartScan();
              _scan(context);
            },
          ),
        ];

      case ScanNotFound(:final message):
        body = StatusPanel(
          kind: StatusKind.error,
          large: true,
          title: "NOT FOUND",
          message: message,
        );
        actions = [rescan];

      case ScanFailed(:final message):
        body = StatusPanel(
          kind: StatusKind.error,
          large: true,
          title: "LOOKUP FAILED",
          message: message,
        );
        actions = [rescan];
    }

    return Column(
      children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [body]),
        ),
        StepActions(children: actions),
      ],
    );
  }

  Widget _start(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "Scan the label on the empty reel",
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          "The reel the SMT machine has run out of.",
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 32),
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
