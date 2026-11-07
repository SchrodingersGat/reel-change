import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "package:reel_change/core/app_log.dart";
import "package:reel_change/ui/theme.dart";

/// Shows everything logged since the app was launched (newest first).
/// The log is held in memory only and is discarded when the app closes.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.log});

  final AppLog log;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  LogLevel _minLevel = LogLevel.debug;

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: widget.log.export(minLevel: _minLevel)),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Log copied to the clipboard")),
      );
    }
  }

  Future<void> _clear() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Clear the log?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("CANCEL"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("CLEAR"),
          ),
        ],
      ),
    );
    if (ok == true) widget.log.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Log"),
        actions: [
          IconButton(
            tooltip: "Copy log",
            icon: const Icon(Icons.copy),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: "Clear log",
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.log,
          builder: (context, _) {
            final entries = widget.log.entries.reversed
                .where((e) => e.level.index >= _minLevel.index)
                .toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: SegmentedButton<LogLevel>(
                    segments: const [
                      ButtonSegment(value: LogLevel.debug, label: Text("All")),
                      ButtonSegment(value: LogLevel.info, label: Text("Info")),
                      ButtonSegment(
                        value: LogLevel.warning,
                        label: Text("Warn"),
                      ),
                      ButtonSegment(
                        value: LogLevel.error,
                        label: Text("Error"),
                      ),
                    ],
                    selected: {_minLevel},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _minLevel = s.first),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    "${entries.length} of ${widget.log.length} entries since the app was started. "
                    "The log is kept in memory only, and is discarded when the app closes.",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(
                          child: Text(
                            "Nothing logged",
                            style: TextStyle(fontSize: 18),
                          ),
                        )
                      : ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) =>
                              _LogTile(entry: entries[i]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (entry.level) {
      LogLevel.debug => (
        Icons.bug_report_outlined,
        Theme.of(context).colorScheme.outline,
      ),
      LogLevel.info => (
        Icons.info_outline,
        Theme.of(context).colorScheme.primary,
      ),
      LogLevel.warning => (Icons.warning_amber_rounded, StatusColors.warning),
      LogLevel.error => (Icons.error, StatusColors.error),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22, semanticLabel: entry.level.name),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${entry.timeLabel}  ·  ${entry.category}",
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                SelectableText(
                  entry.message,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
