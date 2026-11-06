import "package:flutter/material.dart";

import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

/// Transfer complete.
class DoneStep extends StatelessWidget {
  const DoneStep({super.key, required this.workflow});

  final LoadWorkflow workflow;

  @override
  Widget build(BuildContext context) {
    final StockItemInfo item = workflow.selected!.item;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StatusPanel(
                kind: StatusKind.ok,
                large: true,
                title: "TRANSFERRED",
                message:
                    "Reel ${item.label} (${formatQuantity(workflow.transferredQuantity)}"
                    "${workflow.isPartial ? " of ${formatQuantity(item.quantity)}" : ""}) "
                    "has been moved into ${workflow.machine.pathstring}.",
                child: MpnText(item.mpn, color: Colors.white, size: 28),
              ),
              if (workflow.isAlternate) ...[
                const SizedBox(height: 12),
                const StatusPanel(
                  kind: StatusKind.warning,
                  title: "Alternate MPN recorded",
                  message:
                      "The alternate MPN confirmation was saved in the stock item's history.",
                ),
              ],
            ],
          ),
        ),
        StepActions(
          children: [
            BigActionButton(
              label: "START NEXT REEL",
              icon: Icons.qr_code_scanner,
              color: StatusColors.ok,
              height: 96,
              onPressed: workflow.reset,
            ),
          ],
        ),
      ],
    );
  }
}
