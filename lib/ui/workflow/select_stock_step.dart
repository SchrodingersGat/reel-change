import "package:flutter/material.dart";

import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/scanner/scanner_page.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

/// Step 2: choose a replacement reel from stock, verify it by scanning its
/// label, and confirm.
class SelectStockStep extends StatelessWidget {
  const SelectStockStep({
    super.key,
    required this.workflow,
    required this.server,
  });

  final LoadWorkflow workflow;
  final String server;

  Future<void> _scanReel(BuildContext context) async {
    final String title = workflow.selected == null
        ? "Scan the replacement reel"
        : "Scan reel ${workflow.selected!.item.label}";
    final String? barcode = await scanBarcode(context, title: title);
    if (barcode != null) await workflow.verifyScan(barcode);
  }

  Future<void> _confirm(BuildContext context) async {
    if (workflow.isAlternate) {
      final StockItemInfo item = workflow.selected!.item;
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: StatusColors.warning,
            size: 48,
          ),
          title: const Text("Load an alternate MPN?"),
          content: Text(
            "Expected MPN ${workflow.expected!.manufacturerPart.mpn}.\n"
            "This reel is MPN ${item.mpn}.\n\n"
            "Only continue if this alternate is approved for the job. "
            "The confirmation is recorded in InvenTree.",
            style: const TextStyle(fontSize: 17),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("CANCEL"),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: StatusColors.warning,
                minimumSize: const Size(160, 48),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text("USE ALTERNATE"),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    workflow.confirmSelection();
  }

  @override
  Widget build(BuildContext context) {
    final ResolvedPart expected = workflow.expected!;

    final bool loading =
        workflow.busy &&
        workflow.candidates.isEmpty &&
        workflow.stockError == null;

    final (String title, String instruction) = _heading();

    return StepLayout(
      title: title,
      instruction: instruction,
      banner: ExpectedPartHeader(part: expected),
      body: loading ? StepBusy(message: workflow.busyMessage) : _list(context),
      actions: loading ? const [] : _actions(context),
    );
  }

  /// The action the user needs to take next.
  (String, String) _heading() {
    final StockCandidate? selected = workflow.selected;
    final String source = workflow.source.pathstring;

    if (selected == null) {
      return (
        "Select Replacement Reel",
        "Pick the reel you have from $source, or scan its label.",
      );
    }
    if (!workflow.selectionVerified) {
      return (
        "Scan Selected Reel",
        "Scan the label on reel ${selected.item.label} to confirm it is the one you picked.",
      );
    }
    if (workflow.isAlternate) {
      return (
        "Confirm Alternate Reel",
        "This reel has a different MPN. Only continue if the alternate is approved.",
      );
    }
    return ("Confirm Reel", "Reel ${selected.item.label} is verified.");
  }

  Widget _list(BuildContext context) {
    final String? error = workflow.stockError;

    if (error != null) {
      return StepContent(
        children: [
          StatusPanel(
            kind: StatusKind.error,
            large: true,
            title: "COULD NOT LOAD STOCK",
            message: error,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: workflow.loadCandidates,
            icon: const Icon(Icons.refresh),
            label: const Text("RETRY"),
          ),
        ],
      );
    }

    final exact = workflow.exactCandidates;
    final alternates = workflow.alternateCandidates;
    final broken = workflow.dataErrorCandidates;

    if (workflow.candidates.isEmpty) {
      return StepContent(
        children: [
          StatusPanel(
            kind: StatusKind.error,
            large: true,
            title: "NO STOCK",
            message:
                "There is no stock of ${workflow.expected!.part.displayName} in ${workflow.source.pathstring}.",
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: workflow.loadCandidates,
            icon: const Icon(Icons.refresh),
            label: const Text("REFRESH"),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: workflow.loadCandidates,
      child: StepContent(
        children: [
          _SectionHeader(
            kind: StatusKind.ok,
            title: "Exact MPN match (${exact.length})",
            empty: exact.isEmpty
                ? "No reels with the exact MPN in the source location."
                : null,
          ),
          for (final c in exact)
            _CandidateTile(candidate: c, workflow: workflow),
          if (alternates.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionHeader(
              kind: StatusKind.warning,
              title: "Alternate MPN - same part (${alternates.length})",
            ),
            for (final c in alternates)
              _CandidateTile(candidate: c, workflow: workflow),
          ],
          if (broken.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionHeader(
              kind: StatusKind.error,
              title: "Needs data fix - cannot be used (${broken.length})",
            ),
            for (final c in broken) _BrokenTile(candidate: c, server: server),
          ],
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final StockCandidate? selected = workflow.selected;
    final bool busy = workflow.busy;

    final List<Widget> children = [];

    if (workflow.verifyMessage.isNotEmpty) {
      if (workflow.verifyIssue != null) {
        children.add(
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: DataIssuePanel(
                issue: workflow.verifyIssue!,
                server: server,
              ),
            ),
          ),
        );
      } else {
        children.add(
          StatusPanel(
            kind: workflow.verifyIsError ? StatusKind.error : StatusKind.ok,
            title: workflow.verifyIsError ? "NOT VERIFIED" : "REEL VERIFIED",
            message: workflow.verifyMessage,
          ),
        );
      }
    }

    if (selected != null && workflow.selectionVerified) {
      if (workflow.isAlternate) {
        children.add(
          StatusPanel(
            kind: StatusKind.warning,
            title: "ALTERNATE MPN",
            message:
                "Expected ${workflow.expected!.manufacturerPart.mpn}, this reel is ${selected.item.mpn}. "
                "You will be asked to confirm.",
          ),
        );
        children.add(
          BigActionButton(
            label: "CONFIRM ALTERNATE",
            icon: Icons.warning_amber_rounded,
            color: StatusColors.warning,
            busy: busy,
            onPressed: () => _confirm(context),
          ),
        );
      } else {
        children.add(
          BigActionButton(
            label: "CONFIRM REEL",
            icon: Icons.check,
            color: StatusColors.ok,
            busy: busy,
            onPressed: () => _confirm(context),
          ),
        );
      }
      children.add(
        OutlinedButton.icon(
          onPressed: busy ? null : () => _scanReel(context),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text("SCAN A DIFFERENT REEL"),
        ),
      );
    } else {
      children.add(
        BigActionButton(
          label: selected == null
              ? "SCAN REEL"
              : "SCAN REEL ${selected.item.label}",
          icon: Icons.qr_code_scanner,
          busy: busy,
          onPressed: () => _scanReel(context),
        ),
      );
    }

    return children;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.kind, required this.title, this.empty});

  final StatusKind kind;
  final String title;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final Color color = statusColor(context, kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon(kind), color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (empty != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 32),
              child: Text(empty!, style: const TextStyle(fontSize: 16)),
            ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.candidate, required this.workflow});

  final StockCandidate candidate;
  final LoadWorkflow workflow;

  @override
  Widget build(BuildContext context) {
    final StockItemInfo item = candidate.item;
    final bool selected = workflow.selected?.item.pk == item.pk;
    final bool alternate = candidate.kind == CandidateKind.alternate;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      key: Key("candidate-${item.pk}"),
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: workflow.busy ? null : () => workflow.select(candidate),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 32,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Reel ${item.label}",
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "Qty ${formatQuantity(item.quantity)}  ·  ${item.locationPath}",
                      style: const TextStyle(fontSize: 16),
                    ),
                    Text(
                      "MPN ${item.mpn}${item.sku.isEmpty ? "" : "  ·  SKU ${item.sku}"}",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: alternate
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: alternate ? StatusColors.warning : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected && workflow.selectionVerified)
                const Icon(Icons.verified, color: StatusColors.ok, size: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrokenTile extends StatelessWidget {
  const _BrokenTile({required this.candidate, required this.server});

  final StockCandidate candidate;
  final String server;

  @override
  Widget build(BuildContext context) {
    final StockItemInfo item = candidate.item;
    final String reason = item.supplierPartId == null
        ? "No supplier part - MPN unknown"
        : "Supplier part ${item.sku} has no manufacturer part (MPN)";
    final String path = item.supplierPartId == null
        ? "web/stock/item/${item.pk}"
        : "web/purchasing/supplier-part/${item.supplierPartId}";

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: StatusColors.error.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StatusColors.error),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.block, size: 32, color: StatusColors.error),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Reel ${item.label}  ·  Qty ${formatQuantity(item.quantity)}",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    reason,
                    style: const TextStyle(
                      fontSize: 16,
                      color: StatusColors.error,
                    ),
                  ),
                  SelectableText(
                    "Fix: $server$path",
                    style: const TextStyle(fontSize: 14),
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
