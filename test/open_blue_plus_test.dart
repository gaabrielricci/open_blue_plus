import 'dart:async';

import 'package:flutter/services.dart';
import 'package:open_blue_plus/open_blue_plus.dart';
import 'package:open_blue_plus/src/device.dart' show BleDeviceInternal;
import 'package:open_blue_plus/src/manager.dart' show recheckScanFilters;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('open_blue_plus/methods');
  const codec = StandardMethodCodec();

  /// Pushes an event as if it came from the native side.
  Future<void> nativeEvent(Map<String, Object?> event) =>
      messenger.handlePlatformMessage(
        'open_blue_plus/events',
        codec.encodeSuccessEnvelope(event),
        (_) {},
      );

  final calls = <MethodCall>[];
  final allCalls =
      <String>[]; // never cleared: shows what BleManager did at start-up
  Completer<void>? connectGate;
  Completer<void>? disconnectGate;
  Completer<void>? startScanGate;
  List<Object?> connectedReply = const [];
  var failStopScan = false;
  var adapterReply = 'on';
  List<Object?>? servicesReply;

  setUp(() {
    calls.clear();
    connectGate = null;
    disconnectGate = null;
    startScanGate = null;
    connectedReply = const [];
    failStopScan = false;
    adapterReply = 'on';
    servicesReply = null;
    messenger.setMockMethodCallHandler(
        const MethodChannel('open_blue_plus/events'), (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      allCalls.add(call.method);
      switch (call.method) {
        case 'getConnectedDevices':
          return connectedReply;
        case 'getAdapterState':
          return adapterReply;
        case 'getBondedDevices':
          return [
            {'id': 'AA:AA:AA:AA:AA:99', 'name': 'MPT-II'},
          ];
        case 'getBondState':
          return 'bonded';
        case 'discoverServices':
          if (servicesReply != null) return servicesReply;
          return [
            {
              'uuid': '0000180d-0000-1000-8000-00805f9b34fb',
              'primary': true,
              'characteristics': [
                {
                  'uuid': '00002a37-0000-1000-8000-00805f9b34fb',
                  'properties': 0x12,
                  'descriptors': ['00002902-0000-1000-8000-00805f9b34fb'],
                },
              ],
            },
          ];
        case 'read':
          return Uint8List.fromList([1, 2, 3]);
        case 'connect':
          await connectGate?.future;
          return null;
        case 'disconnect':
          await disconnectGate?.future;
          return null;
        case 'startScan':
          await startScanGate?.future;
          return null;
        case 'stopScan':
          if (failStopScan) throw PlatformException(code: 'busy');
          return null;
        case 'write':
          throw PlatformException(
              code: 'gatt_error', message: 'nope', details: 133);
      }
      return null;
    });
    // Make sure the manager subscribed to events.
    BleManager.instance;
  });

  group('BleUuid', () {
    test('expands 16-bit, 32-bit and normalises 128-bit', () {
      expect(BleUuid('180D').value, '0000180d-0000-1000-8000-00805f9b34fb');
      expect(BleUuid('0000180d').value, '0000180d-0000-1000-8000-00805f9b34fb');
      expect(BleUuid('6E400001B5A3F393E0A9E50E24DCCA9E').value,
          '6e400001-b5a3-f393-e0a9-e50e24dcca9e');
      expect(BleUuid.short(0x2902), BleUuid('2902'));
      expect(BleUuid('180d').toString(), '180d');
    });

    test('rejects garbage', () {
      expect(() => BleUuid('xyz'), throwsFormatException);
      expect(() => BleUuid('12345'), throwsFormatException);
    });
  });

  test('properties decode bit flags', () {
    const p = CharacteristicProperties(0x12);
    expect(p.read, isTrue);
    expect(p.notify, isTrue);
    expect(p.write, isFalse);
  });

  test('scan results are collected per device and sorted by rssi', () async {
    await BleManager.instance.startScan();
    final ble = BleManager.instance;
    await nativeEvent({
      'type': 'scanResult',
      'id': 'AA:AA:AA:AA:AA:01',
      'rssi': -80,
      'localName': 'far',
      'manufacturerData': {
        0x004C: Uint8List.fromList([9])
      },
      'serviceUuids': ['0000180d-0000-1000-8000-00805f9b34fb'],
    });
    await nativeEvent({
      'type': 'scanResult',
      'id': 'AA:AA:AA:AA:AA:02',
      'rssi': -40,
      'name': 'near',
    });
    await nativeEvent({
      'type': 'scanResult',
      'id': 'AA:AA:AA:AA:AA:01',
      'rssi': -70,
      'localName': 'far',
    });
    final results = ble.lastScanResults;
    expect(results.map((r) => r.device.id),
        ['AA:AA:AA:AA:AA:02', 'AA:AA:AA:AA:AA:01']);
    expect(results.last.rssi, -70);
    expect(results.first.device.name, 'near');
    expect(
        identical(results.last.device, BleDevice.fromId('AA:AA:AA:AA:AA:01')),
        isTrue);
    await ble.stopScan();
    expect(ble.isScanningNow, isFalse);
  });

  test('connect, discover, read and notifications', () async {
    final d = BleDevice.fromId('AA:AA:AA:AA:AA:10');
    await d.connect();
    expect(d.isConnected, isTrue);

    final services = await d.discoverServices();
    final c = services.single.characteristic(BleUuid('2a37'))!;
    expect(c.descriptors.single.uuid, BleUuids.cccd);

    final values = <List<int>>[];
    final sub = c.onValue.listen(values.add);
    expect(await c.read(), [1, 2, 3]);
    expect(calls.last.arguments['characteristic'],
        '00002a37-0000-1000-8000-00805f9b34fb');

    await nativeEvent({
      'type': 'value',
      'id': d.id,
      'service': '0000180d-0000-1000-8000-00805f9b34fb',
      'characteristic': '00002a37-0000-1000-8000-00805f9b34fb',
      'value': Uint8List.fromList([7, 7]),
    });
    await Future<void>.delayed(Duration.zero); // let the stream deliver
    expect(values, [
      [7, 7]
    ]);
    expect(c.lastValue, [7, 7]);

    await expectLater(
      c.write([1]),
      throwsA(isA<BleException>()
          .having((e) => e.code, 'code', 'gatt_error')
          .having((e) => e.status, 'status', 133)),
    );

    await nativeEvent(
        {'type': 'connectionState', 'id': d.id, 'connected': false});
    expect(d.isConnected, isFalse);
    expect(d.services, isEmpty);
    await sub.cancel();
  });

  group('streams emit the current value and never miss a change', () {
    test('connectionState sees a change made right after listen', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AA:20');
      final seen = <DeviceConnectionState>[];
      final sub = d.connectionState.listen(seen.add);
      d.handleConnectionEvent(true); // synchronously after listen
      await pumpEventQueue();
      expect(seen, [
        DeviceConnectionState.disconnected,
        DeviceConnectionState.connected
      ]);
      d.handleConnectionEvent(false);
      await sub.cancel();
    });

    test('onMtu and isScanning start with the current value', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AA:21');
      final mtus = <int>[];
      final sub = d.onMtu.listen(mtus.add);
      d.handleMtuEvent(185);
      await pumpEventQueue();
      expect(mtus, [23, 185]);
      await sub.cancel();

      final ble = BleManager.instance;
      final flags = <bool>[];
      final sub2 = ble.isScanning.listen(flags.add);
      await ble.startScan();
      await ble.stopScan();
      await pumpEventQueue();
      expect(flags, [false, true, false]);
      await sub2.cancel();
    });

    test('adapterState emits the queried state, then changes', () async {
      adapterReply = 'off';
      final seen = <AdapterState>[];
      final sub = BleManager.instance.adapterState.listen(seen.add);
      await pumpEventQueue();
      await nativeEvent({'type': 'adapterState', 'state': 'on'});
      await pumpEventQueue();
      expect(seen, [AdapterState.off, AdapterState.on]);
      await sub.cancel();
    });

    test('waitUntilOn completes when the adapter turns on', () async {
      adapterReply = 'off';
      await BleManager.instance.getAdapterState();
      final wait = BleManager.instance.waitUntilOn();
      await pumpEventQueue();
      await nativeEvent({'type': 'adapterState', 'state': 'on'});
      await wait;
      expect(BleManager.instance.adapterStateNow, AdapterState.on);
    });
  });

  group('connection state', () {
    test('a stale connected:false does not hide a pending connect', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AA:30');
      connectGate = Completer<void>();
      final connecting = d.connect();
      await pumpEventQueue();
      expect(d.state, DeviceConnectionState.connecting);
      await nativeEvent(
          {'type': 'connectionState', 'id': d.id, 'connected': false});
      expect(d.state, DeviceConnectionState.connecting);
      connectGate!.complete();
      await connecting;
      expect(d.state, DeviceConnectionState.connected);
      await d.disconnect();
      expect(d.state, DeviceConnectionState.disconnected);
    });

    test('disconnect() during connect cancels it', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AA:31');
      connectGate = Completer<void>();
      final connecting = d.connect();
      await pumpEventQueue();
      await d.disconnect();
      expect(d.state, DeviceConnectionState.disconnected);
      connectGate!.complete(); // native reply arrives late
      await expectLater(
          connecting,
          throwsA(isA<BleException>()
              .having((e) => e.code, 'code', 'connect_failed')));
      expect(d.state, DeviceConnectionState.disconnected);
    });

    test('disconnect() while disconnected still reaches the platform',
        () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AA:32');
      final states = <DeviceConnectionState>[];
      final sub = d.connectionState.listen(states.add);
      await d.disconnect();
      await pumpEventQueue();
      expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
      expect(states, [DeviceConnectionState.disconnected]);
      await sub.cancel();
    });
  });

  test('values are routed per characteristic; read sets lastValue at once',
      () async {
    final d = BleDevice.fromId('AA:AA:AA:AA:AA:40');
    await d.connect();
    final c = (await d.discoverServices()).single.characteristics.single;
    expect(await c.read(), [1, 2, 3]);
    expect(c.lastValue, [1, 2, 3]); // before any value event

    final values = <List<int>>[];
    final sub = c.onValue.listen(values.add);
    // Another characteristic on the same device.
    d.handleValueEvent('0000180d-0000-1000-8000-00805f9b34fb', 0,
        '00002a38-0000-1000-8000-00805f9b34fb', 0, Uint8List.fromList([9]));
    // Non canonical notation still reaches the right characteristic.
    d.handleValueEvent('180D', 0, '2A37', 0, Uint8List.fromList([5]));
    await pumpEventQueue();
    expect(values, [
      [5]
    ]);
    expect(c.lastValue, [5]);
    await sub.cancel();
    await d.disconnect();
  });

  test('scan list stays sorted as rssi changes', () async {
    final ble = BleManager.instance;
    await ble.startScan();
    Future<void> adv(String id, int rssi) =>
        nativeEvent({'type': 'scanResult', 'id': id, 'rssi': rssi});
    await adv('BB:00:00:00:00:01', -60);
    await adv('BB:00:00:00:00:02', -50);
    await adv('BB:00:00:00:00:03', -70);
    await adv('BB:00:00:00:00:03', -40);
    await adv('BB:00:00:00:00:02', -90);
    expect(ble.lastScanResults.map((r) => r.rssi), [-40, -60, -90]);
    expect(ble.lastScanResults.map((r) => r.device.id),
        ['BB:00:00:00:00:03', 'BB:00:00:00:00:01', 'BB:00:00:00:00:02']);
    await ble.stopScan();
  });

  test('a failing stopScan from the scan timeout is not an uncaught error',
      () async {
    final ble = BleManager.instance;
    await ble.startScan(timeout: const Duration(milliseconds: 10));
    failStopScan = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ble.isScanningNow, isFalse);
  });

  test('device ids are case-insensitive for MAC and Apple ids only', () {
    expect(
        identical(BleDevice.fromId('aa:bb:cc:dd:ee:ff'),
            BleDevice.fromId('AA:BB:CC:DD:EE:FF')),
        isTrue);
    expect(BleDevice.fromId('12345678-abcd-abcd-abcd-1234567890ab').id,
        '12345678-ABCD-ABCD-ABCD-1234567890AB');
    expect(BleDevice.fromId('aBc+/xYz==').id, 'aBc+/xYz==');
  });

  test('bonded devices and bond state', () async {
    final list = await BleManager.instance.bondedDevices();
    expect(list.single.id, 'AA:AA:AA:AA:AA:99');
    expect(list.single.name, 'MPT-II');
    expect(await list.single.bondState(), BondState.bonded);
    expect(BondState.parse('weird'), BondState.unknown);
  });

  test('connect requests MTU 512 and oversized writes without response fail',
      () async {
    final d = BleDevice.fromId('AA:AA:AA:AA:AA:77');
    await d.connect();
    final mtuCall = calls.lastWhere((c) => c.method == 'requestMtu');
    expect(mtuCall.arguments['mtu'], 512);
    // The mock does not negotiate, so the MTU stays 23 (20 bytes per packet).
    final services = await d.discoverServices();
    final c = services.single.characteristics.single;
    await expectLater(
      c.write(List.filled(21, 0), withoutResponse: true),
      throwsA(isA<BleException>()
          .having((e) => e.code, 'code', 'invalid_argument')),
    );
    await d.disconnect();
  });

  group('duplicated UUIDs and included services', () {
    const svc = '0000180a-0000-1000-8000-00805f9b34fb';
    const chr = '00002a29-0000-1000-8000-00805f9b34fb';
    const inc = '0000aaaa-0000-1000-8000-00805f9b34fb';
    Map<String, Object?> char() =>
        {'uuid': chr, 'properties': 0x12, 'descriptors': <String>[]};

    setUp(() {
      servicesReply = [
        {
          'uuid': svc,
          'primary': true,
          'included': [2],
          'characteristics': [char(), char()]
        },
        {
          'uuid': svc,
          'primary': true,
          'characteristics': [char()]
        },
        {'uuid': inc, 'primary': false, 'characteristics': <Object?>[]},
      ];
    });

    test('every instance gets its own index, args and values', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AB:01');
      await d.connect();
      final services = await d.discoverServices();
      expect(services.map((s) => s.index), [0, 1, 0]);
      expect(services[0].characteristics.map((c) => c.index), [0, 1]);
      expect(services[0].includedServices.single.uuid, BleUuid(inc));
      expect(services[2].isSecondary, isTrue);

      final second = services[0].characteristics[1];
      final other = services[1].characteristics[0];
      await second.read();
      final read = calls.lastWhere((c) => c.method == 'read');
      expect(read.arguments['serviceIndex'], 0);
      expect(read.arguments['characteristicIndex'], 1);

      final got = <String>[];
      final s1 = second.onValue.listen((v) => got.add('second $v'));
      final s2 = other.onValue.listen((v) => got.add('other $v'));
      await nativeEvent({
        'type': 'value',
        'id': d.id,
        'service': svc,
        'serviceIndex': 1,
        'characteristic': chr,
        'characteristicIndex': 0,
        'value': Uint8List.fromList([7]),
      });
      await nativeEvent({
        'type': 'value',
        'id': d.id,
        'service': svc,
        'serviceIndex': 0,
        'characteristic': chr,
        'characteristicIndex': 1,
        'value': Uint8List.fromList([8]),
      });
      await pumpEventQueue();
      expect(got, ['other [7]', 'second [8]']);
      expect(services[0].characteristics[0].lastValue, isNull);
      await s1.cancel();
      await s2.cancel();
      await d.disconnect();
    });
  });

  group('scan filters', () {
    Future<void> adv(String id,
            {String? name, Map<int, List<int>>? manu, List<String>? uuids}) =>
        nativeEvent({
          'type': 'scanResult',
          'id': id,
          'rssi': -50,
          'localName': name,
          'manufacturerData': {
            for (final e in (manu ?? const <int, List<int>>{}).entries)
              e.key: Uint8List.fromList(e.value),
          },
          'serviceUuids': uuids ?? const <String>[],
        });

    test('lists are OR-combined, prefix is AND-ed and args reach the platform',
        () async {
      final ble = BleManager.instance;
      await ble.startScan(
        withKeywords: ['ens'],
        withRemoteIds: ['cc:00:00:00:00:09'],
        withManufacturerData: [
          const ManufacturerDataFilter(0x004C,
              data: [0x02, 0x15], mask: [0xFF, 0x0F]),
        ],
        withNamePrefix: 'S',
      );
      final args =
          calls.lastWhere((c) => c.method == 'startScan').arguments as Map;
      expect(args['remoteIds'], ['CC:00:00:00:00:09']);
      expect((args['manufacturerData'] as List).single['id'], 0x004C);

      await adv('CC:00:00:00:00:01', name: 'Sensor'); // keyword + prefix
      await adv('CC:00:00:00:00:02', name: 'Lens'); // keyword, wrong prefix
      await adv('CC:00:00:00:00:03', name: 'Sx', manu: {
        0x004C: [0x02, 0xA5, 9]
      }); // masked match
      await adv('CC:00:00:00:00:04', name: 'Sy', manu: {
        0x004C: [0x03, 0x15]
      }); // mask mismatch
      await adv('CC:00:00:00:00:09', name: 'Sz'); // remote id
      await adv('CC:00:00:00:00:05', name: 'Sw'); // nothing
      expect(ble.lastScanResults.map((r) => r.device.id).toSet(),
          {'CC:00:00:00:00:01', 'CC:00:00:00:00:03', 'CC:00:00:00:00:09'});
      expect(BleDevice.fromId('CC:00:00:00:00:01').advName, 'Sensor');
      await ble.stopScan();
    });

    test('results after stopScan are ignored', () async {
      final ble = BleManager.instance;
      await ble.startScan();
      await ble.stopScan();
      await adv('CC:00:00:00:01:01');
      expect(ble.lastScanResults, isEmpty);
    });

    test('invalid arguments are rejected before reaching the platform',
        () async {
      final ble = BleManager.instance;
      expect(() => ble.startScan(continuousDivisor: 0), throwsArgumentError);
      expect(() => ble.startScan(removeIfGone: const Duration(seconds: 1)),
          throwsArgumentError);
      expect(
          () => ble.startScan(withManufacturerData: [
                const ManufacturerDataFilter(1, data: [1, 2], mask: [1]),
              ]),
          throwsArgumentError);
    });

    test('removeIfGone drops silent devices', () async {
      final ble = BleManager.instance;
      await ble.startScan(
          allowDuplicates: true,
          removeIfGone: const Duration(milliseconds: 200));
      await adv('CC:00:00:00:02:01');
      expect(ble.lastScanResults, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(ble.lastScanResults, isEmpty);
      await ble.stopScan();
    });

    test('onScanResults starts empty when not scanning', () async {
      final ble = BleManager.instance;
      await ble.startScan();
      await adv('CC:00:00:00:03:01');
      await ble.stopScan();
      expect(await ble.scanResults.first, hasLength(1));
      expect(await ble.onScanResults.first, isEmpty);
    });
  });

  group('device events', () {
    test('disconnect reason, services reset and notifying flags', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AC:01');
      await d.connect();
      final c = (await d.discoverServices()).single.characteristics.single;
      await c.setNotify(true);
      expect(c.isNotifying, isTrue);
      expect(
          calls
              .lastWhere((x) => x.method == 'setNotify')
              .arguments['forceIndications'],
          false);

      var resets = 0;
      final sub = d.onServicesReset.listen((_) => resets++);
      await nativeEvent({'type': 'servicesReset', 'id': d.id});
      await pumpEventQueue();
      expect(resets, 1);
      expect(d.services, isEmpty);
      expect(c.isNotifying, isFalse);
      await sub.cancel();

      final events = <BleConnectionEvent>[];
      final all = BleManager.instance.events.onConnectionStateChanged
          .listen(events.add);
      await nativeEvent({
        'type': 'connectionState',
        'id': d.id,
        'connected': false,
        'reason': 0x08,
        'reasonText': 'supervision timeout',
      });
      await pumpEventQueue();
      expect(d.state, DeviceConnectionState.disconnected);
      expect(d.disconnectReason?.code, 0x08);
      expect(events.single.reason?.description, 'supervision timeout');
      await all.cancel();

      await d.connect();
      await d.disconnect();
      expect(d.disconnectReason?.code, isNull);
      expect(d.disconnectReason?.description, 'disconnected by the app');
    });

    test('cancelWhenDisconnected', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AC:02');
      await d.connect();
      var cancelled = false;
      final ctrl = StreamController<int>(onCancel: () => cancelled = true);
      d.cancelWhenDisconnected(ctrl.stream.listen((_) {}));
      expect(cancelled, isFalse);
      await d.disconnect();
      await pumpEventQueue();
      expect(cancelled, isTrue);
    });

    test('bond state from createBond, removeBond and events', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AC:03');
      final bonds = <BleBondEvent>[];
      final sub =
          BleManager.instance.events.onBondStateChanged.listen(bonds.add);
      await d.createBond(pin: '123456');
      final call = calls.lastWhere((c) => c.method == 'createBond');
      expect(call.arguments['pin'], '123456');
      expect(call.arguments['timeoutMs'], 90000);
      expect(d.bondStateNow, BondState.bonded);
      await nativeEvent({'type': 'bondState', 'id': d.id, 'state': 'none'});
      await pumpEventQueue();
      expect(d.bondStateNow, BondState.none);
      expect(d.prevBondState, BondState.bonded);
      expect(bonds.map((b) => b.state), [BondState.bonded, BondState.none]);
      await sub.cancel();
    });

    test('name, mtu and phy events', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AC:04');
      await nativeEvent({'type': 'name', 'id': d.id, 'name': 'Renamed'});
      await nativeEvent({'type': 'phy', 'id': d.id, 'tx': 2, 'rx': 3});
      await pumpEventQueue();
      expect(d.name, 'Renamed');
      expect(d.phyNow?.tx, BlePhy.le2m);
      expect(d.phyNow?.rx, BlePhy.leCoded);
      expect(() => d.setPreferredPhy(tx: {}, rx: {BlePhy.le1m}),
          throwsArgumentError);
    });

    test('CCCD writes update isNotifying and descriptor values', () async {
      final d = BleDevice.fromId('AA:AA:AA:AA:AC:05');
      await d.connect();
      final c = (await d.discoverServices()).single.characteristics.single;
      final cccd = c.descriptor(BleUuids.cccd)!;
      await cccd.write([1, 0]);
      expect(c.isNotifying, isTrue);
      expect(cccd.lastValue, [1, 0]);
      await cccd.write([0, 0]);
      expect(c.isNotifying, isFalse);
      await d.disconnect();
    });
  });

  test('native log events reach the logs stream', () async {
    final ble = BleManager.instance;
    await ble.setLogLevel(BleLogLevel.info, print: false);
    expect(calls.last.arguments, {'level': BleLogLevel.info.index});
    final logs = <BleLogRecord>[];
    final sub = ble.logs.listen(logs.add);
    await nativeEvent({'type': 'log', 'level': 3, 'message': 'hello'});
    await nativeEvent({'type': 'log', 'level': 5, 'message': 'too verbose'});
    await pumpEventQueue();
    expect(logs.map((l) => l.message), ['hello']);
    expect(logs.single.native, isTrue);
    await sub.cancel();
    await ble.setLogLevel(BleLogLevel.none);
  });

  test('start-up adopts the previous session without side effects (rule 17)',
      () {
    expect(
        allCalls.take(3), ['setLogLevel', 'stopScan', 'getConnectedDevices']);
  });

  group('review fixes', () {
    test('connectedDevices adopts connections that survived a hot restart',
        () async {
      connectedReply = [
        {'id': 'dd:00:00:00:00:01', 'name': 'kept'},
      ];
      final list = await BleManager.instance.connectedDevices();
      expect(list.single.id, 'DD:00:00:00:00:01');
      expect(list.single.isConnected, isTrue);
      await list.single.disconnect();
    });

    test('connect after disconnect() of a pending connect starts a new attempt',
        () async {
      final d = BleDevice.fromId('DD:00:00:00:00:02');
      connectGate = Completer<void>();
      final first = d.connect();
      await pumpEventQueue();
      await d.disconnect();
      final second = d.connect();
      expect(identical(first, second), isFalse);
      expect(calls.where((c) => c.method == 'connect'), hasLength(2));
      connectGate!.complete();
      await expectLater(
          first,
          throwsA(isA<BleException>()
              .having((e) => e.code, 'code', 'connect_failed')));
      await second;
      expect(d.state, DeviceConnectionState.connected);
      await d.disconnect();
    });

    test('a failed connect turns autoConnect off', () async {
      final d = BleDevice.fromId('DD:00:00:00:00:03');
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'connect') {
          throw PlatformException(code: 'connect_failed');
        }
        return null;
      });
      await expectLater(
          d.connect(autoConnect: true), throwsA(isA<BleException>()));
      expect(d.isAutoConnectEnabled, isFalse);
      expect(d.state, DeviceConnectionState.disconnected);
    });

    test('a duplicate connected:false keeps the known disconnect reason',
        () async {
      final d = BleDevice.fromId('DD:00:00:00:00:04');
      await d.connect();
      await d.disconnect();
      await nativeEvent(
          {'type': 'connectionState', 'id': d.id, 'connected': false});
      expect(d.disconnectReason?.description, 'disconnected by the app');
    });

    test('a stale connected:true while disconnecting is ignored', () async {
      final d = BleDevice.fromId('DD:00:00:00:00:05');
      await d.connect();
      disconnectGate = Completer<void>();
      final done = d.disconnect();
      await pumpEventQueue();
      await nativeEvent(
          {'type': 'connectionState', 'id': d.id, 'connected': true});
      expect(d.state, DeviceConnectionState.disconnecting);
      disconnectGate!.complete();
      await done;
      expect(d.state, DeviceConnectionState.disconnected);
    });

    test('streams can be listened to more than once', () async {
      final d = BleDevice.fromId('DD:00:00:00:00:06');
      final s = d.connectionState;
      final a = await s.first;
      final b = await s.first;
      expect([
        a,
        b
      ], [
        DeviceConnectionState.disconnected,
        DeviceConnectionState.disconnected
      ]);
    });

    test('a superseded startScan does not leave its timeout armed', () async {
      final ble = BleManager.instance;
      startScanGate = Completer<void>();
      final first = ble.startScan(timeout: const Duration(milliseconds: 20));
      final second = ble.startScan();
      startScanGate!.complete();
      await first;
      await second;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(ble.isScanningNow, isTrue);
      await ble.stopScan();
    });

    test('scanFailed before startScan returns fails the call', () async {
      final ble = BleManager.instance;
      startScanGate = Completer<void>();
      final start = ble.startScan();
      await pumpEventQueue();
      await nativeEvent({'type': 'scanFailed', 'code': 2});
      startScanGate!.complete();
      await expectLater(
          start,
          throwsA(isA<BleException>()
              .having((e) => e.code, 'code', 'gatt_error')
              .having((e) => e.status, 'status', 2)));
      expect(ble.isScanningNow, isFalse);
    });

    test('malformed events are not uncaught errors', () async {
      final ble = BleManager.instance;
      await ble.startScan();
      await nativeEvent({
        'type': 'scanResult',
        'id': 'DD:00:00:00:00:07',
        'rssi': -50,
        'serviceUuids': ['not-a-uuid']
      });
      expect(ble.lastScanResults, isEmpty);
      await ble.stopScan();
    });

    test('Web: the chosen device is not re-filtered in Dart', () async {
      final ble = BleManager.instance;
      recheckScanFilters = false;
      addTearDown(() => recheckScanFilters = true);
      await ble.startScan(withServices: [BleUuid('180d')]);
      // The chooser result carries no advertised services.
      await nativeEvent(
          {'type': 'scanResult', 'id': 'web-id==', 'rssi': 0, 'name': 'HR'});
      expect(ble.lastScanResults.single.device.id, 'web-id==');
      await ble.stopScan();
    });
  });
}
