// Recipe: keep a device connected (wearables, sensors, printers).
//
// With `autoConnect` the OS reconnects by itself whenever the device comes
// back in range (Android, Windows). Elsewhere this recipe retries with a
// back-off. After every (re)connection the services are discovered and
// notifications re-enabled, because both are lost when the link drops.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:open_blue_plus/open_blue_plus.dart';

/// Keeps [device] connected until [stop] is called, running [onConnected]
/// after every successful connection (discover services, subscribe, ...).
class KeepConnected {
  final BleDevice device;
  final Future<void> Function(BleDevice device) onConnected;

  StreamSubscription<DeviceConnectionState>? _stateSub;
  StreamSubscription<void>? _resetSub;
  bool _running = false;

  KeepConnected(this.device, this.onConnected);

  static bool get _osReconnects =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> start() async {
    _running = true;
    _stateSub = device.connectionState.listen((s) {
      if (s == DeviceConnectionState.connected) {
        _setUp();
      } else if (s == DeviceConnectionState.disconnected && _running) {
        debugPrint('link lost: ${device.disconnectReason}');
        if (!_osReconnects) _retry();
      }
    });
    // The peripheral changed its services (e.g. after a firmware update).
    _resetSub = device.onServicesReset.listen((_) => _setUp());
    if (_osReconnects) {
      unawaited(device.connect(autoConnect: true).catchError((Object e) {
        debugPrint('autoConnect failed: $e');
      }));
    } else {
      await _retry();
    }
  }

  Future<void> _setUp() async {
    try {
      await device.discoverServices();
      await onConnected(device);
    } catch (e) {
      debugPrint('set-up after connection failed: $e');
    }
  }

  Future<void> _retry() async {
    var delay = const Duration(seconds: 1);
    while (_running && !device.isConnected) {
      try {
        await device.connect(timeout: const Duration(seconds: 10));
        return;
      } on BleException catch (e) {
        debugPrint('connect failed (${e.code}), retrying in $delay');
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(seconds: 30)) delay *= 2;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _stateSub?.cancel();
    await _resetSub?.cancel();
    await device.disconnect();
  }
}
