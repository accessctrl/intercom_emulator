import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/log_entry.dart';

class AppLogger extends ChangeNotifier {
  final List<LogEntry> _entries = <LogEntry>[];

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  void debug(String message, {String? details}) {
    _add(LogLevel.debug, message, details: details);
  }

  void info(String message, {String? details}) {
    _add(LogLevel.info, message, details: details);
  }

  void warning(String message, {String? details}) {
    _add(LogLevel.warning, message, details: details);
  }

  void error(String message, {String? details}) {
    _add(LogLevel.error, message, details: details);
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _add(LogLevel level, String message, {String? details}) {
    final entry = LogEntry(level: level, message: message, details: details);
    _entries.insert(0, entry);

    final levelText = _levelText(level);
    final detailsText = (details == null || details.isEmpty)
        ? ''
        : ' | $details';
    final line =
        '[INTERCOM-EMU][$levelText] ${entry.timestamp.toIso8601String()} | $message$detailsText';

    // Visible in `flutter run` output and DevTools logging console.
    debugPrint(line);

    // Force explicit terminal output for remote debugging sessions.
    if (level == LogLevel.error) {
      stderr.writeln(line);
    } else {
      stdout.writeln(line);
    }

    // Forward to platform logs (logcat on Android) with severity mapping.
    dev.log(
      '$message${detailsText.isEmpty ? '' : detailsText}',
      name: 'intercom_emulator',
      level: _devLogLevel(level),
      time: entry.timestamp,
    );

    if (_entries.length > 500) {
      _entries.removeRange(500, _entries.length);
    }
    notifyListeners();
  }

  String _levelText(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'DEBUG',
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
  }

  int _devLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 500,
      LogLevel.info => 800,
      LogLevel.warning => 900,
      LogLevel.error => 1000,
    };
  }
}
