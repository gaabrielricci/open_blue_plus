# Testing your app without Bluetooth

Every call of the plugin goes through one replaceable transport,
`BleChannel.backend`. In unit and widget tests you can install a fake
backend that answers calls and emits events, and test your Bluetooth code
without hardware, emulators or platform channels.

The protocol (method names, arguments and event shapes) is documented in
[PROTOCOL.md](../PROTOCOL.md). A fake only needs to answer the methods your
code uses.

## A fake backend

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:open_blue_plus/platform_interface.dart';

class FakeBle implements BleBackend {
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Simulates something the device does on its own (notification,
  /// disconnection, ...).
  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) async {
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
        return Uint8List.fromList([87]);
      case 'getConnectedDevices':
        return [];
      default: // connect, disconnect, stopScan, setNotify, requestMtu...
        return null;
    }
  }
}
```

Failures are thrown as `BleException('code', 'message')`, exactly what the
real platforms produce:

```dart
case 'connect':
  throw const BleException('connect_failed', 'out of range');
```

## Using it

Install the fake **before the first use of `BleManager.instance`** (the
manager subscribes to the backend's events when it is created):

```dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = FakeBle();
  BleChannel.backend = fake;
  final ble = BleManager.instance;

  test('reads the battery', () async {
    await ble.startScan(withServices: [BleUuid('180f')]);
    final result = (await ble.scanResults.firstWhere((r) => r.isNotEmpty)).single;
    await ble.stopScan();

    final device = result.device;
    await device.connect();
    await device.discoverServices();
    final level = device.service(BleUuid('180f'))!.characteristic(BleUuid('2a19'))!;
    expect(await level.read(), [87]);

    // A notification from the "device":
    fake.emit({
      'type': 'value',
      'id': device.id,
      'service': FakeBle.batteryService,
      'characteristic': FakeBle.batteryLevel,
      'value': Uint8List.fromList([86]),
    });
  });
}
```

This exact code runs in the package's own test suite
([test/fake_backend_test.dart](../test/fake_backend_test.dart)).

## Tips

* `BleManager.instance` and `BleDevice` objects are singletons per process.
  Use distinct device ids per test, or put each scenario in its own test
  file (each file runs in a fresh isolate).
* Useful events to simulate: `connectionState` (`connected: false` with an
  optional `reason`), `value`, `mtu`, `adapterState` (`state: 'off'`),
  `servicesReset`, `bondState`.
* Wrap the plugin behind your own repository class if you prefer mocking at
  a higher level; the fake backend is for testing that class itself.
