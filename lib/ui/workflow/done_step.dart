import "dart:async";

import "package:flutter/material.dart";

import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

/// Transfer complete. Optionally returns to step 1 after a countdown.
class DoneStep extends StatefulWidget {
  const DoneStep({
    super.key,
    required this.workflow,
    this.autoReturn = false,
    this.seconds = AppPreferences.autoReturnSeconds,
  });

  final LoadWorkflow workflow;

  /// Return to step 1 automatically after [seconds].
  final bool autoReturn;
  final int seconds;

  @override
  State<DoneStep> createState() => _DoneStepState();
}

class _DoneStepState extends State<DoneStep> {
  Timer? _timer;
  late int _remaining = widget.seconds;

  bool get _counting => _timer != null;

  @override
  void initState() {
    super.initState();
    if (widget.autoReturn) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    if (_remaining <= 1) {
      _stop();
      widget.workflow.reset();
      return;
    }
    setState(() => _remaining--);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    final LoadWorkflow workflow = widget.workflow;

    // Already reset (this screen is about to be replaced)
    if (workflow.selected == null) return const SizedBox.shrink();

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
            if (_counting) ...[
              Text(
                "Returning to start in $_remaining s",
                key: const Key("auto-return-countdown"),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
              LinearProgressIndicator(
                value: _remaining / widget.seconds,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
            BigActionButton(
              label: "START NEXT REEL",
              icon: Icons.qr_code_scanner,
              color: StatusColors.ok,
              height: 96,
              onPressed: () {
                _stop();
                workflow.reset();
              },
            ),
            if (_counting)
              OutlinedButton(
                key: const Key("auto-return-stay"),
                onPressed: () => setState(_stop),
                child: const Text("STAY ON THIS SCREEN"),
              ),
          ],
        ),
      ],
    );
  }
}
