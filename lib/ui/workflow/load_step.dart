import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

/// Step 3: review the transfer, optionally adjust the quantity, and confirm.
class LoadStep extends StatelessWidget {
  const LoadStep({super.key, required this.workflow});

  final LoadWorkflow workflow;

  Future<void> _changeQuantity(BuildContext context) async {
    final StockItemInfo item = workflow.selected!.item;
    final double? q = await showDialog<double>(
      context: context,
      builder: (_) =>
          _QuantityDialog(available: item.quantity, current: workflow.quantity),
    );
    if (q != null) workflow.setQuantity(q);
  }

  @override
  Widget build(BuildContext context) {
    final StockItemInfo item = workflow.selected!.item;
    final bool partial = workflow.isPartial;
    final bool busy = workflow.busy;
    final double remaining = item.quantity - workflow.quantity;

    return StepLayout(
      title: "Load Into Machine",
      instruction:
          "Load the reel onto the feeder, check the quantity, then transfer it "
          "into ${workflow.machine.pathstring}.",
      banner: ExpectedPartHeader(part: workflow.expected!),
      body: StepContent(
        children: [
          // Quantity first: it is the one thing the user may need to change
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: partial
                    ? StatusColors.warning
                    : Theme.of(context).colorScheme.outlineVariant,
                width: partial ? 3 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Quantity to move",
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            Text(
                              formatQuantity(workflow.quantity),
                              key: const Key("transfer-quantity"),
                              style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.bold,
                                color: partial ? StatusColors.warning : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, kBigButtonHeight),
                        ),
                        onPressed: busy ? null : () => _changeQuantity(context),
                        icon: const Icon(Icons.edit),
                        label: const Text("CHANGE"),
                      ),
                    ],
                  ),
                  Text(
                    partial
                        ? "PARTIAL: ${formatQuantity(workflow.quantity)} of ${formatQuantity(item.quantity)}. "
                              "${formatQuantity(remaining)} will remain in ${item.locationPath} as a separate stock item."
                        : "Full reel (all ${formatQuantity(item.quantity)} in stock)",
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: partial ? FontWeight.bold : FontWeight.normal,
                      color: partial ? StatusColors.warning : null,
                    ),
                  ),
                  if (partial) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => workflow.setQuantity(item.quantity),
                      child: const Text("USE FULL REEL"),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Row(label: "Reel", value: item.label, strong: true),
                  _Row(
                    label: "MPN",
                    value: workflow.isAlternate
                        ? "${item.mpn}  (ALTERNATE)"
                        : item.mpn,
                    color: workflow.isAlternate ? StatusColors.warning : null,
                    strong: true,
                  ),
                  _Row(label: "From", value: item.locationPath),
                  _Row(
                    label: "To",
                    value: workflow.machine.pathstring,
                    strong: true,
                  ),
                ],
              ),
            ),
          ),
          if (workflow.transferError != null) ...[
            const SizedBox(height: 16),
            StatusPanel(
              kind: StatusKind.error,
              large: true,
              title: "TRANSFER NOT MADE",
              message: workflow.transferError!,
            ),
          ],
        ],
      ),
      actions: [
        BigActionButton(
          label: "TRANSFER INTO MACHINE",
          icon: Icons.move_down,
          color: partial ? StatusColors.warning : StatusColors.ok,
          height: 88,
          busy: busy,
          onPressed: workflow.transfer,
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.strong = false,
    this.color,
  });

  final String label;
  final String value;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 17,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: strong ? 20 : 17,
              fontWeight: strong ? FontWeight.bold : FontWeight.normal,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.available, required this.current});

  final double available;
  final double current;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: formatQuantity(widget.current),
  );

  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String? error = validateQuantity(_controller.text, widget.available);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, double.parse(_controller.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final bool whole = widget.available == widget.available.roundToDouble();

    return AlertDialog(
      title: const Text("Quantity to move"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "In stock: ${formatQuantity(widget.available)}",
            style: const TextStyle(fontSize: 17),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: !whole),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(whole ? r"[0-9]" : r"[0-9.]"),
              ),
            ],
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            decoration: InputDecoration(errorText: _error, errorMaxLines: 3),
            onSubmitted: (_) => _submit(),
          ),
        ],
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
}
