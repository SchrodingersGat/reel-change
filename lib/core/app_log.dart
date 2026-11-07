import "dart:collection";
import "dart:developer" as developer;

import "package:flutter/foundation.dart";

enum LogLevel { debug, info, warning, error }

class LogEntry {
  LogEntry(this.level, this.category, this.message) : time = DateTime.now();

  final DateTime time;
  final LogLevel level;

  /// Where the entry came from, e.g. "api", "auth", "workflow".
  final String category;
  final String message;

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, "0");
    return "${two(time.hour)}:${two(time.minute)}:${two(time.second)}."
        "${time.millisecond.toString().padLeft(3, "0")}";
  }

  @override
  String toString() =>
      "$timeLabel ${level.name.toUpperCase().padRight(7)} [$category] $message";
}

/// In-memory log of what the app has done since it was launched.
///
/// - Kept in memory only: never written to storage, and discarded when the app closes
/// - Bounded: the oldest entries are dropped beyond [capacity]
/// - Must never contain secrets: no passwords, cookies, CSRF tokens or
///   request headers are logged anywhere in the app
class AppLog extends ChangeNotifier {
  AppLog({this.capacity = 2000});

  final int capacity;

  final Queue<LogEntry> _entries = Queue<LogEntry>();

  /// Oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  int get errorCount => _entries.where((e) => e.level == LogLevel.error).length;

  final DateTime startedAt = DateTime.now();

  void add(LogLevel level, String category, String message) {
    final entry = LogEntry(level, category, message);

    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }

    if (kDebugMode) {
      developer.log(message, name: category, level: _developerLevel(level));
    }

    notifyListeners();
  }

  void debug(String category, String message) =>
      add(LogLevel.debug, category, message);
  void info(String category, String message) =>
      add(LogLevel.info, category, message);
  void warning(String category, String message) =>
      add(LogLevel.warning, category, message);
  void error(String category, String message) =>
      add(LogLevel.error, category, message);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Plain-text copy of the log (for copying to a support request).
  String export({LogLevel minLevel = LogLevel.debug}) {
    final buffer = StringBuffer(
      "Reel Change log - app started ${startedAt.toIso8601String()}\n",
    );
    for (final e in _entries.where((e) => e.level.index >= minLevel.index)) {
      buffer.writeln(e);
    }
    return buffer.toString();
  }

  static int _developerLevel(LogLevel level) => switch (level) {
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warning => 900,
    LogLevel.error => 1000,
  };
}

/// The app-wide log.
final AppLog appLog = AppLog();

/// Shorten untrusted / long text (e.g. barcode data) for the log.
String logSnippet(String text, {int max = 80}) {
  final String clean = text.replaceAll(RegExp(r"[\x00-\x1F\x7F]"), "·");
  return clean.length <= max
      ? clean
      : "${clean.substring(0, max)}... (${clean.length} chars)";
}
