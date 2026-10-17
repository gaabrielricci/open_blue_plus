// Mirrors doc/testing.md: an app's code tested against a fake backend,
// without Bluetooth hardware or platform channels.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_blue_plus/open_blue_plus.dart';
import 'package:open_blue_plus/platform_interface.dart';

/// A fake peripheral: one battery service, readable and notifying.
class FakeBle implements BleBackend {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  int battery = 87;

  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Simulates something the device does on its own.
  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) async {
    calls.add(method);
    switch (method) {
      case 'getAdapterState':
        return 'on';
      case 'startScan':
        emit({
          'type': 'scanResult',
          'id': 'AA:BB:CC:DD:EE:01',
          'rssi': -42,
          'localName': 'Fake Sensor',
          'serviceUuids': [batteryService],
        });
        return null;
      case 'discoverServices':
        return [
          {
            'uuid': batteryService,
            'primary': true,
            'characteristics': [
              {'uuid': batteryLevel, 'properties': 0x12, 'descriptors': []},
            ],
          },
        ];
      case 'read':
        return Uint8List.fromList([battery]);
      case 'getConnectedDevices':
        return [];
      default: // connect, disconnect, stopScan, setNotify, requestMtu...
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = FakeBle();
  // Must happen before the first use of BleManager.instance.
  BleChannel.backend = fake;
  final ble = BleManager.instance;

  test('scan, connect, read and notifications against a fake backend',
      () async {
    await ble.startScan(withServices: [BleUuid('180f')]);
    final result =
        (await ble.scanResults.firstWhere((r) => r.isNotEmpty)).single;
    await ble.stopScan();
    expect(result.advertisement.localName, 'Fake Sensor');

    final device = result.device;
    await device.connect();
    await device.discoverServices();
    final level =
        device.service(BleUuid('180f'))!.characteristic(BleUuid('2a19'))!;
    expect(await level.read(), [87]);

    final values = <int>[];
    final sub = level.onValue.listen((v) => values.add(v.first));
    await level.setNotify(true);
    fake.emit({
      'type': 'value',
      'id': device.id,
      'service': FakeBle.batteryService,
      'characteristic': FakeBle.batteryLevel,
      'value': Uint8List.fromList([86]),
    });
    await pumpEventQueue();
    expect(values, [86]);

    fake.emit({'type': 'connectionState', 'id': device.id, 'connected': false});
    await pumpEventQueue();
    expect(device.isConnected, isFalse);
    await sub.cancel();
  });
}
