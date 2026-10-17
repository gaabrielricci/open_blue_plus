import 'dart:async';

import 'package:flutter/services.dart';

import 'exception.dart';
import 'log.dart';

/// Transport between the Dart API and a platform implementation.
///
/// Every backend speaks the same protocol (see `PROTOCOL.md`): requests are
/// method names with a map of arguments, and everything the platform reports
/// on its own arrives as a map with a `type` key on [events].
///
/// Android, iOS, macOS and Windows use [MethodChannelBackend]. Pure Dart
/// implementations (Web, Linux) replace [BleChannel.backend] at registration.
abstract class BleBackend {
  /// Runs [method]. Failures must be thrown as [BleException] (or
  /// [PlatformException], which is converted).
  Future<Object?> invoke(String method, Map<String, dynamic>? args);

  /// Unsolicited events (adapterState, scanResult, connectionState, ...).
  Stream<Map<String, dynamic>> get events;
}

/// Backend backed by native code through platform channels.
class MethodChannelBackend implements BleBackend {
  static const MethodChannel _methods = MethodChannel('open_blue_plus/methods');
  static const EventChannel _events = EventChannel('open_blue_plus/events');

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) =>
      _methods.invokeMethod<Object?>(method, args);

  @override
  late final Stream<Map<String, dynamic>> events = _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));
}

/// Bridge between the public classes and the active [BleBackend].
class BleChannel {
  BleChannel._();

  /// The active backend. Platform packages written in Dart replace it in
  /// their `registerWith`.
  static BleBackend backend = MethodChannelBackend();

  /// Events of the active backend.
  static Stream<Map<String, dynamic>> get events => backend.events;

  /// Runs [method] on the backend, converting [PlatformException] into
  /// [BleException] (`details` becomes [BleException.status] when an int).
  static Future<T?> invoke<T>(String method,
      [Map<String, dynamic>? args]) async {
    BleLog.log(
        BleLogLevel.debug, () => '-> $method${args == null ? '' : ' $args'}');
    try {
      final r = await backend.invoke(method, args) as T?;
      BleLog.log(BleLogLevel.verbose, () => '<- $method: $r');
      return r;
    } on PlatformException catch (e) {
      final details = e.details;
      final error =
          BleException(e.code, e.message, details is int ? details : null);
      BleLog.log(BleLogLevel.error, () => '<- $method failed: $error');
      throw error;
    } on BleException catch (e) {
      BleLog.log(BleLogLevel.error, () => '<- $method failed: $e');
      rethrow;
    }
  }

  /// Runs [method] and fails with a `timeout` [BleException] after [timeout].
  ///
  /// The timeout is also sent as `timeoutMs` so backends with their own
  /// per-operation timeout never give up before the caller does.
  static Future<T?> invokeWithTimeout<T>(
    String method,
    Map<String, dynamic> args,
    Duration timeout,
  ) {
    final withTimeout = {...args, 'timeoutMs': timeout.inMilliseconds};
    return invoke<T>(method, withTimeout).timeout(timeout, onTimeout: () {
      throw BleException('timeout', '$method did not complete in $timeout');
    });
  }
}
