// Recipe: read the standard Battery Level (0x180F / 0x2A19) of a device,
// and keep it up to date when the device notifies changes.
import 'dart:async';

import 'package:open_blue_plus/open_blue_plus.dart';

final batteryService = BleUuid('180f');
final batteryLevel = BleUuid('2a19');

/// Returns the battery percentage (0-100) of a connected [device], or null if
/// it does not expose the Battery service. [onChange] receives later updates
/// when the characteristic supports notifications.
Future<int?> readBattery(BleDevice device,
    {void Function(int)? onChange}) async {
  if (device.services.isEmpty) await device.discoverServices();
  final c = device.service(batteryService)?.characteristic(batteryLevel);
  if (c == null) return null;

  if (onChange != null && c.properties.notify) {
    final sub = c.onValue.listen((v) {
      if (v.isNotEmpty) onChange(v[0]);
    });
    device.cancelWhenDisconnected(sub);
    await c.setNotify(true);
  }
  if (!c.properties.read) return c.lastValue?.first;
  final v = await c.read();
  return v.isEmpty ? null : v[0];
}
