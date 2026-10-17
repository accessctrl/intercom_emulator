enum LogLevel { debug, info, warning, error }

class LogEntry {
  LogEntry({
    required this.level,
    required this.message,
    DateTime? timestamp,
    this.details,
  }) : timestamp = timestamp ?? DateTime.now();

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? details;
}
