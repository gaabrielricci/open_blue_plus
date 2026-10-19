// The Android Classic SPP path, seen from Dart: the backend presents the
// serial link as one service (0x1101) with one writable, notifying
// characteristic, and `connect` answers which transport it used.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_blue_plus/open_blue_plus.dart';
import 'package:open_blue_plus/platform_interface.dart';

const _printer = 'AA:BB:CC:DD:EE:10';
const _phone = 'AA:BB:CC:DD:EE:20';
const _spp = '00001101-0000-1000-8000-00805f9b34fb';

class FakeAndroid implements BleBackend {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final connectArgs = <Map<String, dynamic>>[];
  final written = <Uint8List>[];

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void emit(Map<String, dynamic> e) => _events.add(e);

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) async {
    switch (method) {
      case 'getAdapterState':
        return 'on';
      case 'getConnectedDevices':
        return [];
      case 'connect':
        connectArgs.add(args!);
        if (args['id'] != _printer) return 'le';
        emit({'type': 'mtu', 'id': _printer, 'mtu': 515});
        return 'classic';
      case 'requestMtu':
        return args!['id'] == _printer ? 515 : 247;
      case 'discoverServices':
        return [
          {
            'uuid': _spp,
            'primary': true,
            'characteristics': [
              {
                'uuid': _spp,
                'properties': 0x1C,
                'descriptors': ['00002902-0000-1000-8000-00805f9b34fb'],
              },
            ],
          },
        ];
      case 'write':
        written.add(args!['value'] as Uint8List);
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = FakeAndroid();
  BleChannel.backend = fake;

  test('auto is sent by default and a Classic link is reported', () async {
    final printer = BleDevice.fromId(_printer);
    expect(printer.transport, isNull);
    await printer.connect();
    expect(fake.connectArgs.last['transport'], 'auto');
    expect(printer.transport, BleTransport.classic);
    expect(printer.mtu, 515);

    final services = await printer.discoverServices();
    final serial = services.single.characteristic(BleUuids.serialPort)!;
    expect(serial.properties.write, isTrue);
    expect(serial.properties.writeWithoutResponse, isTrue);
    expect(serial.properties.notify, isTrue);

    // A 512-byte chunk fits the reported MTU without response.
    await serial.write(List.filled(512, 0x1B), withoutResponse: true);
    expect(fake.written.single.length, 512);
    await printer.disconnect();
  });

  test('an LE device reports le, and a forced transport is passed on',
      () async {
    final phone = BleDevice.fromId(_phone);
    await phone.connect(transport: BleTransport.le);
    expect(fake.connectArgs.last['transport'], 'le');
    expect(phone.transport, BleTransport.le);
    await phone.disconnect();
  });
}
