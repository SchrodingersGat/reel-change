import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/theme.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

enum StatusKind { ok, warning, error, info }

Color statusColor(BuildContext context, StatusKind kind) => switch (kind) {
  StatusKind.ok => StatusColors.ok,
  StatusKind.warning => StatusColors.warning,
  StatusKind.error => StatusColors.error,
  StatusKind.info => Theme.of(context).colorScheme.primary,
};

IconData statusIcon(StatusKind kind) => switch (kind) {
  StatusKind.ok => Icons.check_circle,
  StatusKind.warning => Icons.warning_amber_rounded,
  StatusKind.error => Icons.error,
  StatusKind.info => Icons.info,
};

/// A coloured status block: always icon + title word + text, never colour alone.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.kind,
    required this.title,
    this.message = "",
    this.child,
    this.large = false,
  });

  final StatusKind kind;
  final String title;
  final String message;
  final Widget? child;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final Color color = statusColor(context, kind);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(large ? 24 : 16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  statusIcon(kind),
                  color: Colors.white,
                  size: large ? 48 : 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: large ? 28 : 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                message,
                style: const TextStyle(fontSize: 17, color: Colors.white),
              ),
            ],
            if (child != null) ...[const SizedBox(height: 12), child!],
          ],
        ),
      ),
    );
  }
}

/// A data problem that must be fixed in InvenTree. Shows where to fix it.
class DataIssuePanel extends StatelessWidget {
  const DataIssuePanel({super.key, required this.issue, required this.server});

  final DataIssue issue;
  final String server;

  @override
  Widget build(BuildContext context) {
    final String url = issue.webPath.isEmpty ? "" : "$server${issue.webPath}";

    return StatusPanel(
      kind: StatusKind.error,
      large: true,
      title: "DATA ERROR: ${issue.title.toUpperCase()}",
      message: issue.detail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "This reel cannot be used until the data is fixed in InvenTree.",
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (url.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      url,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: "Copy link",
                    icon: const Icon(Icons.copy, color: Colors.black87),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Link copied")),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Large, clear display of an MPN.
class MpnText extends StatelessWidget {
  const MpnText(this.mpn, {super.key, this.color, this.size = 34});

  final String mpn;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SelectableText(
    mpn,
    style: TextStyle(
      fontFamily: "monospace",
      fontSize: size,
      fontWeight: FontWeight.bold,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    ),
  );
}

class _LabelValue extends StatelessWidget {
  const _LabelValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// The scanned part: MPN (large), manufacturer, internal part, and the scanned reel if any.
class PartSummaryCard extends StatelessWidget {
  const PartSummaryCard({super.key, required this.part});

  final ResolvedPart part;

  @override
  Widget build(BuildContext context) {
    final StockItemInfo? reel = part.stockItem;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("MPN", style: Theme.of(context).textTheme.labelLarge),
            MpnText(part.manufacturerPart.mpn),
            const SizedBox(height: 8),
            _LabelValue("Manufacturer", part.manufacturerPart.manufacturerName),
            _LabelValue("Part", part.part.displayName),
            _LabelValue("IPN", part.part.ipn),
            _LabelValue("Description", part.part.description),
            if (reel != null) ...[
              const Divider(height: 24),
              _LabelValue("Scanned reel", reel.label),
              _LabelValue("Quantity", formatQuantity(reel.quantity)),
              _LabelValue("Location", reel.locationPath),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact line showing the part being loaded (steps 2 and 3).
class ExpectedPartHeader extends StatelessWidget {
  const ExpectedPartHeader({super.key, required this.part});

  final ResolvedPart part;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Loading", style: Theme.of(context).textTheme.labelLarge),
        MpnText(part.manufacturerPart.mpn, size: 24),
        Text(
          [
            part.manufacturerPart.manufacturerName,
            part.part.displayName,
          ].where((s) => s.isNotEmpty).join(" · "),
          style: const TextStyle(fontSize: 16),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

/// A very large primary action button.
class BigActionButton extends StatelessWidget {
  const BigActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.height = 80,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;
  final double height;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      minimumSize: Size.fromHeight(height),
      backgroundColor: color,
      textStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    ),
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 32),
                const SizedBox(width: 12),
              ],
              Flexible(child: Text(label, textAlign: TextAlign.center)),
            ],
          ),
  );
}

/// Progress through the three workflow steps, shown at the bottom of the screen.
class WorkflowProgressBar extends StatelessWidget {
  const WorkflowProgressBar({super.key, required this.step});

  final WorkflowStep step;

  static const List<String> _labels = ["Scan part", "Select reel", "Load"];

  @override
  Widget build(BuildContext context) {
    final int current = switch (step) {
      WorkflowStep.scanPart => 0,
      WorkflowStep.selectStock => 1,
      WorkflowStep.load => 2,
      WorkflowStep.done => 3,
    };

    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      key: const Key("workflow-progress"),
      color: scheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          for (int i = 0; i < _labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                label:
                    "Step ${i + 1} of 3, ${_labels[i]}, "
                    "${i < current
                        ? "complete"
                        : i == current
                        ? "current"
                        : "not started"}",
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: i < current
                            ? StatusColors.ok
                            : i == current
                            ? scheme.primary
                            : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (i < current)
                          const Icon(
                            Icons.check,
                            size: 18,
                            color: StatusColors.ok,
                          )
                        else
                          Text(
                            "${i + 1}",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: i == current
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _labels[i],
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: i == current
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: i <= current
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Padding for the fixed action area at the bottom of a step.
class StepActions extends StatelessWidget {
  const StepActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
      ],
    ),
  );
}

/// Full-area busy indicator for a step.
class StepBusy extends StatelessWidget {
  const StepBusy({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(strokeWidth: 6),
        ),
        const SizedBox(height: 24),
        Text(message, style: Theme.of(context).textTheme.titleLarge),
      ],
    ),
  );
}
