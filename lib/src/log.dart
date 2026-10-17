import 'dart:async';

import 'package:flutter/foundation.dart';

/// Verbosity of the plugin's logs (see `BleManager.setLogLevel`).
enum BleLogLevel {
  /// No logs.
  none,

  /// Failures only.
  error,

  /// Failures and suspicious situations.
  warning,

  /// Main events (connections, scans).
  info,

  /// Every call to the platform and every event.
  debug,

  /// Everything, including scan results and call results.
  verbose;
}

/// One log line, from the Dart layer or the platform backend.
class BleLogRecord {
  /// Severity of the line.
  final BleLogLevel level;

  /// The text.
  final String message;

  /// Whether the line came from the platform backend.
  final bool native;

  /// When the line was logged in Dart.
  final DateTime time;

  /// Creates a record logged now.
  BleLogRecord(this.level, this.message, {this.native = false})
      : time = DateTime.now();

  @override
  String toString() =>
      '[ble${native ? ':native' : ''}] ${level.name}: $message';
}

/// Internal logger shared by every class of the plugin.
class BleLog {
  BleLog._();

  /// Current level.
  static BleLogLevel level = BleLogLevel.none;

  /// Whether log lines are also printed with `debugPrint`.
  static bool printLogs = true;

  static final _ctrl = StreamController<BleLogRecord>.broadcast();

  /// Every enabled log line.
  static Stream<BleLogRecord> get records => _ctrl.stream;

  /// Whether lines of level [l] are logged.
  static bool enabled(BleLogLevel l) =>
      l != BleLogLevel.none && l.index <= level.index;

  /// Logs [message] if [l] is enabled. [message] is only built when needed.
  static void log(BleLogLevel l, String Function() message,
      {bool native = false}) {
    if (!enabled(l)) return;
    final r = BleLogRecord(l, message(), native: native);
    if (printLogs) debugPrint(r.toString());
    if (_ctrl.hasListener) _ctrl.add(r);
  }
}
