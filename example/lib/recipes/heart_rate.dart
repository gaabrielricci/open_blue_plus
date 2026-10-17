// Recipe: standard Heart Rate monitor (chest straps, watches, fitness bands).
//
// Scans for the Heart Rate service (0x180D), connects to the first device
// found, subscribes to Heart Rate Measurement (0x2A37) and decodes it.
import 'dart:async';
import 'dart:typed_data';

import 'package:open_blue_plus/open_blue_plus.dart';

final _ble = BleManager.instance;
final heartRateService = BleUuid('180d');
final heartRateMeasurement = BleUuid('2a37');

/// Streams beats per minute from the first heart rate monitor found.
///
/// Cancel the returned subscription and call `device.disconnect()` when done.
Future<(BleDevice, StreamSubscription<Uint8List>)> listenToHeartRate(
  void Function(int bpm) onBpm,
) async {
  await _ble.waitUntilOn();

  // 1. Find a device advertising the Heart Rate service.
  final found = _ble.onScanResult.first;
  final ScanResult result;
  try {
    await _ble.startScan(withServices: [heartRateService]);
    result = await found.timeout(const Duration(seconds: 15));
  } finally {
    await _ble.stopScan();
  }

  // 2. Connect and discover.
  final device = result.device;
  await device.connect();
  await device.discoverServices();
  final hrm =
      device.service(heartRateService)?.characteristic(heartRateMeasurement);
  if (hrm == null) {
    await device.disconnect();
    throw const BleException('not_found', 'Heart Rate Measurement missing');
  }

  // 3. Listen first, then enable notifications, so no value is missed.
  final sub = hrm.onValue.listen((bytes) => onBpm(parseHeartRate(bytes)));
  device.cancelWhenDisconnected(sub);
  await hrm.setNotify(true);
  return (device, sub);
}

/// Decodes a Heart Rate Measurement value (Bluetooth SIG spec): bit 0 of the
/// flags byte tells whether the rate is a uint8 or a little-endian uint16.
int parseHeartRate(List<int> v) {
  if (v.length < 2) return 0;
  final uint16 = v[0] & 0x01 != 0;
  return uint16 && v.length >= 3 ? v[1] | (v[2] << 8) : v[1];
}
