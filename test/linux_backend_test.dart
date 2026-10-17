import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:open_blue_plus/src/channel.dart';
import 'package:open_blue_plus/src/exception.dart';
import 'package:open_blue_plus/src/linux/bluez_mapping.dart';
import 'package:open_blue_plus/src/linux/linux_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hr = '0000180d-0000-1000-8000-00805f9b34fb';
  const custom = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  group('uuid', () {
    test('expands and lowercases', () {
      expect(fullUuid('180D'), hr);
      expect(fullUuid('0000180d'), hr);
      expect(fullUuid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E'), custom);
      expect(fullUuid(BlueZUUID.short(0x180d).toString()), hr);
    });

    test('compares across notations', () {
      expect(sameUuid('180d', hr.toUpperCase()), isTrue);
      expect(sameUuid('180d', '180f'), isFalse);
    });
  });

  group('properties', () {
    test('maps BlueZ flags to the protocol bit layout', () {
      expect(propertiesFromFlags(['read', 'notify']), 0x12);
      expect(
        propertiesFromFlags([
          'broadcast',
          'read',
          'write-without-response',
          'write',
          'notify',
          'indicate',
          'authenticated-signed-writes',
          'extended-properties',
        ]),
        0xff,
      );
      expect(propertiesFromFlags(['reliable-write', 'encrypt-read']), 0x80);
      expect(propertiesFromFlags(const []), 0);
    });
  });

  group('GATT database', () {
    const dev = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF';
    const battery = '0000180f-0000-1000-8000-00805f9b34fb';
    const level = '00002a19-0000-1000-8000-00805f9b34fb';
    const hrm = '00002a37-0000-1000-8000-00805f9b34fb';
    const cccd = '00002902-0000-1000-8000-00805f9b34fb';

    Map<String, Map<String, Object?>> service(String uuid,
            {bool primary = true, List<String> includes = const []}) =>
        {
          gattServiceInterface: {
            'UUID': uuid,
            'Primary': primary,
            'Includes': includes,
          },
        };
    Map<String, Map<String, Object?>> char(String svc, String uuid,
            {List<String> flags = const ['read'], int? mtu}) =>
        {
          gattCharacteristicInterface: {
            'UUID': uuid,
            'Service': svc,
            'Flags': flags,
            if (mtu != null) 'MTU': mtu,
          },
        };
    Map<String, Map<String, Object?>> desc(String ch, String uuid) => {
          gattDescriptorInterface: {'UUID': uuid, 'Characteristic': ch},
        };

    // Inserted out of handle order, with two Battery services (one
    // secondary, included by the heart rate service) and two Battery Level
    // characteristics in the first one.
    final objects = {
      '$dev/service0020': service(hr, includes: ['$dev/service0030']),
      '$dev/service0020/char0021':
          char('$dev/service0020', hrm, flags: ['notify'], mtu: 247),
      '$dev/service0020/char0021/desc0023':
          desc('$dev/service0020/char0021', cccd),
      '$dev/service0010': service(battery),
      '$dev/service0010/char0014': char('$dev/service0010', level),
      '$dev/service0010/char0011': char('$dev/service0010', level),
      '$dev/service0030': service(battery, primary: false),
      '$dev/service0030/char0031': char('$dev/service0030', level),
    };
    final tree = buildGattTree(objects);

    test('lists every service once, in handle order', () {
      expect([
        for (final s in tree) s.path
      ], [
        '$dev/service0010',
        '$dev/service0020',
        '$dev/service0030',
      ]);
      expect([for (final s in tree) s.primary], [true, true, false]);
      expect(tree[1].included, [2]);
      expect([for (final c in tree[0].characteristics) c.path],
          ['$dev/service0010/char0011', '$dev/service0010/char0014']);
      expect(knownMtu(tree.expand((s) => s.characteristics).map((c) => c.mtu)),
          247);
    });

    test('numbers duplicated UUIDs', () {
      expect([for (final s in tree) s.characteristics.first.serviceIndex],
          [0, 0, 1]);
      expect([for (final c in tree[0].characteristics) c.index], [0, 1]);
      expect(tree[2].characteristics.single.valueEvent('X'), {
        'type': 'value',
        'id': 'X',
        'service': battery,
        'serviceIndex': 1,
        'characteristic': level,
        'characteristicIndex': 0,
      });
    });

    test('resolves addresses in the same order', () {
      String? find(String s, int si, String c, int ci) =>
          findCharacteristic(tree, s, si, c, ci)?.path;
      expect(find('180f', 0, '2a19', 0), '$dev/service0010/char0011');
      expect(find('180f', 0, '2a19', 1), '$dev/service0010/char0014');
      expect(find('180F', 1, '2A19', 0), '$dev/service0030/char0031');
      expect(find('180f', 1, '2a19', 1), isNull);
      expect(find('180f', 2, '2a19', 0), isNull);
      expect(find('180d', 0, '2a37', 0), '$dev/service0020/char0021');
      expect(find('180d', 0, '2a19', 0), isNull);
    });

    test('serializes with included services', () {
      expect(serviceToMap(tree[1]), {
        'uuid': hr,
        'primary': true,
        'included': [2],
        'characteristics': [
          {
            'uuid': hrm,
            'properties': 0x10,
            'descriptors': [cccd],
          },
        ],
      });
      expect(serviceToMap(tree[2])['primary'], isFalse);
      expect(serviceToMap(tree[0])['included'], isEmpty);
    });

    test('converts GetManagedObjects values (flags, includes, paths)', () {
      DBusObjectPath p(String s) => DBusObjectPath(s);
      final t = buildGattTree(gattObjectsFromDBus({
        p('$dev/service0001'): {
          gattServiceInterface: {
            'UUID': const DBusString(hr),
            'Primary': const DBusBoolean(true),
            'Includes': DBusArray.objectPath([p('$dev/service0005')]),
          },
        },
        p('$dev/service0001/char0002'): {
          gattCharacteristicInterface: {
            'UUID': const DBusString(hrm),
            'Service': p('$dev/service0001'),
            'Flags': DBusArray.string(['read', 'notify']),
            'MTU': const DBusUint16(185),
            'Value': DBusArray.byte([1, 2]),
          },
          'org.freedesktop.DBus.Properties': {},
        },
        p('$dev/service0001/char0002/desc0004'): {
          gattDescriptorInterface: {
            'UUID': const DBusString(cccd),
            'Characteristic': p('$dev/service0001/char0002'),
          },
        },
        p('$dev/service0005'): {
          gattServiceInterface: {
            'UUID': const DBusString(battery),
            'Primary': const DBusBoolean(false),
            'Includes': DBusArray.objectPath([]),
          },
        },
        // Another device and the device itself are left out.
        p('${dev}0/service0001'): {
          gattServiceInterface: {'UUID': const DBusString(battery)},
        },
        p(dev): {
          'org.bluez.Device1': {'Address': const DBusString('AA')},
        },
      }, '$dev/'));
      expect(t.map((s) => s.uuid), [hr, battery]);
      expect(t[0].included, [1]);
      final c = t[0].characteristics.single;
      expect(c.properties, 0x12);
      expect(c.mtu, 185);
      expect(c.descriptors.single.uuid, cccd);
      expect(t[1].primary, isFalse);
    });

    test('falls back to the path for parents and ignores unknown includes', () {
      final t = buildGattTree({
        '$dev/service0001': {
          gattServiceInterface: {
            'UUID': '1800',
            'Primary': true,
            'Includes': ['$dev/service0099'],
          },
        },
        '$dev/service0001/char0002': {
          gattCharacteristicInterface: {'UUID': '2a00'},
        },
      });
      expect(t.single.included, isEmpty);
      expect(t.single.characteristics.single.uuid,
          '00002a00-0000-1000-8000-00805f9b34fb');
      expect(t.single.characteristics.single.properties, 0);
      expect(t.single.characteristics.single.mtu, isNull);
    });
  });

  group('scan filter', () {
    bool match(
      ScanFilter f, {
      String id = 'AA:BB:CC:DD:EE:FF',
      String? name,
      List<String> uuids = const [],
      Map<int, List<int>> manufacturer = const {},
      Map<String, List<int>> serviceData = const {},
    }) =>
        f.matches(
          id: id,
          name: name,
          serviceUuids: uuids,
          manufacturerData: manufacturer,
          serviceData: serviceData,
        );
    ScanFilter args(Map<String, dynamic> a) => ScanFilter.fromArgs(a);

    test('empty filters match everything', () {
      expect(match(args({})), isTrue);
      expect(
          match(args({'services': [], 'names': [], 'keywords': []})), isTrue);
    });

    test('services match advertised UUIDs in any notation', () {
      final f = args({
        'services': ['180D']
      });
      expect(match(f, uuids: [hr]), isTrue);
      expect(match(f, uuids: ['180d']), isTrue);
      expect(match(f, uuids: [custom]), isFalse);
      // Service data alone does not count (use the serviceData filter).
      expect(
          match(f, serviceData: {
            hr: [1]
          }),
          isFalse);
    });

    test('names match exactly, keywords as substrings', () {
      final names = args({
        'names': ['Polar H10']
      });
      expect(match(names, name: 'Polar H10'), isTrue);
      expect(match(names, name: 'Polar H10 X'), isFalse);
      expect(match(names), isFalse);
      final keywords = args({
        'keywords': ['H10', 'Garmin']
      });
      expect(match(keywords, name: 'Polar H10 123'), isTrue);
      expect(match(keywords, name: 'polar h10'), isFalse);
      expect(match(keywords), isFalse);
    });

    test('remoteIds ignore case', () {
      final f = args({
        'remoteIds': ['aa:bb:cc:dd:ee:ff']
      });
      expect(match(f), isTrue);
      expect(match(f, id: '11:22:33:44:55:66'), isFalse);
    });

    test('manufacturer data matches under a mask', () {
      final f = args({
        'manufacturerData': [
          {
            'id': 0x004c,
            'data': Uint8List.fromList([0x02, 0x15]),
            'mask': Uint8List.fromList([0xff, 0x0f]),
          },
          {'id': 0x0059, 'data': Uint8List(0)},
        ],
      });
      expect(
          match(f, manufacturer: {
            0x004c: [0x02, 0x25, 0x99]
          }),
          isTrue);
      expect(
          match(f, manufacturer: {
            0x004c: [0x02, 0x26]
          }),
          isFalse);
      expect(
          match(f, manufacturer: {
            0x004c: [0x02]
          }),
          isFalse);
      expect(match(f, manufacturer: {0x0059: []}), isTrue);
      expect(
          match(f, manufacturer: {
            0x0006: [0x02, 0x15]
          }),
          isFalse);
    });

    test('service data matches by service and payload', () {
      final f = args({
        'serviceData': [
          {
            'service': '180d',
            'data': Uint8List.fromList([1, 2]),
          },
        ],
      });
      expect(
          match(f, serviceData: {
            hr: [1, 2, 3]
          }),
          isTrue);
      expect(
          match(f, serviceData: {
            '180D': [1, 2]
          }),
          isTrue);
      expect(
          match(f, serviceData: {
            hr: [1, 3]
          }),
          isFalse);
      expect(
          match(f, serviceData: {
            custom: [1, 2]
          }),
          isFalse);
      expect(match(f, uuids: [hr]), isFalse);
    });

    test('list filters are OR-combined', () {
      final f = args({
        'services': [hr],
        'names': ['X'],
        'remoteIds': ['11:22:33:44:55:66'],
      });
      expect(match(f, name: 'X'), isTrue);
      expect(match(f, uuids: [hr], name: 'Y'), isTrue);
      expect(match(f, id: '11:22:33:44:55:66'), isTrue);
      expect(match(f, uuids: [custom], name: 'Y'), isFalse);
    });

    test('namePrefix is AND-combined with the other filters', () {
      ScanFilter prefixed(String p, [Map<String, dynamic> a = const {}]) =>
          args({...a, 'namePrefix': p});
      expect(match(prefixed('Polar'), name: 'Polar H10'), isTrue);
      expect(match(prefixed('Polar'), name: 'Garmin'), isFalse);
      // A nameless advertisement is rejected, not remembered as seen.
      expect(match(prefixed('Polar')), isFalse);
      final svc = {
        'services': [hr]
      };
      expect(match(prefixed('Pol', svc), uuids: [hr], name: 'Polar'), isTrue);
      expect(match(prefixed('Pol', svc), uuids: [hr], name: 'Other'), isFalse);
      expect(
          match(prefixed('Pol', svc), uuids: [custom], name: 'Polar'), isFalse);
      expect(match(prefixed(''), name: 'Any'), isTrue);
    });

    test('a malformed UUID is a FormatException', () {
      expect(
          () => args({
                'services': ['not-a-uuid']
              }),
          throwsFormatException);
    });

    test('BlueZ gets the UUIDs only when services is the only list', () {
      expect(
          args({
            'services': ['180d'],
            'namePrefix': 'P'
          }).discoveryUuids,
          [hr]);
      expect(
          args({
            'services': ['180d'],
            'keywords': ['P']
          }).discoveryUuids,
          isEmpty);
      expect(
          args({
            'services': ['180d'],
            'serviceData': [
              {'service': '180d', 'data': Uint8List(0)}
            ],
          }).discoveryUuids,
          isEmpty);
      expect(args({}).discoveryUuids, isEmpty);
    });

    test('only the properties the filters use trigger a re-check', () {
      expect(args({}).relevantProperties, isEmpty);
      expect(
          args({
            'services': [hr],
            'keywords': ['a'],
          }).relevantProperties,
          {'Name', 'UUIDs'});
      expect(
          args({
            'manufacturerData': [
              {'id': 1, 'data': Uint8List(0)}
            ],
            'serviceData': [
              {'service': hr, 'data': Uint8List(0)}
            ],
          }).relevantProperties,
          {'ManufacturerData', 'ServiceData'});
      expect(args({'namePrefix': 'x'}).relevantProperties, {'Name'});
      expect(
          args({
            'remoteIds': ['AA:BB:CC:DD:EE:FF']
          }).relevantProperties,
          isEmpty);
    });
  });

  test('masked match', () {
    expect(maskedMatch([1, 2, 3], [1, 2], null), isTrue);
    expect(maskedMatch([1], [1, 2], null), isFalse);
    expect(maskedMatch([0xab], [0xa0], [0xf0]), isTrue);
    expect(maskedMatch([0xbb], [0xa0], [0xf0]), isFalse);
    expect(maskedMatch(const [], const [], null), isTrue);
  });

  test('continuousDivisor reports the 1st and then every Nth', () {
    final d = ContinuousDivisor(3);
    expect([for (var i = 0; i < 7; i++) d.shouldReport('A')],
        [true, false, false, true, false, false, true]);
    expect(d.shouldReport('B'), isTrue);
  });

  test('maps Disconnected reasons', () {
    expect(disconnectReason('org.bluez.Reason.Timeout', 'Connection timeout'),
        (code: 0x08, text: 'Connection timeout'));
    expect(disconnectReason('org.bluez.Reason.Remote', '').code, 0x13);
    expect(disconnectReason('org.bluez.Reason.Local', '').code, 0x16);
    expect(disconnectReason('org.bluez.Reason.Authentication', '').code, 0x05);
    expect(disconnectReason('org.bluez.Reason.Unknown', ''),
        (code: null, text: 'org.bluez.Reason.Unknown'));
  });

  test('reads the process start time', () {
    final fields = List.generate(50, (i) => '${i + 3}').join(' ');
    expect(procStartTime('1234 (my app) $fields'), '22');
    expect(procStartTime('1234 (a) b) $fields'), '22');
    expect(procStartTime('garbage'), isNull);
    expect(procStartTime('1 (x) R 1'), isNull);
  });

  test('any non-zero CCCD value enables notifications', () {
    expect(cccdEnables([0x01, 0x00]), isTrue);
    expect(cccdEnables([0x02, 0x00]), isTrue);
    expect(cccdEnables([0x00, 0x01]), isTrue);
    expect(cccdEnables([0x00, 0x00]), isFalse);
    expect(cccdEnables(const []), isFalse);
  });

  test('MTU is known from the first characteristic reporting it', () {
    expect(knownMtu(const []), isNull);
    expect(knownMtu([null, 0]), isNull);
    expect(knownMtu([null, 247, 23]), 247);
  });

  group('ReadEchoFilter', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('passes values through when no read is in flight', () {
      final f = ReadEchoFilter();
      expect(f.onValue(b([1])), [
        b([1])
      ]);
      expect(f.onValue(b([1])), [
        b([1])
      ]);
    });

    test('drops the echo of a read, keeps real notifications', () {
      final f = ReadEchoFilter()..beginRead();
      expect(f.onValue(b([1])), isEmpty); // real notification
      expect(f.onValue(b([2])), isEmpty); // echo of the read
      expect(f.endRead(b([2])), [
        b([1])
      ]);
      expect(f.onValue(b([2])), [
        b([2])
      ]); // later notification, same bytes
    });

    test('drops only one echo when values repeat', () {
      final f = ReadEchoFilter()..beginRead();
      f.onValue(b([5]));
      f.onValue(b([5]));
      expect(f.endRead(b([5])), [
        b([5])
      ]);
    });

    test('a read without echo or a failed read releases everything', () {
      final f = ReadEchoFilter()..beginRead();
      f.onValue(b([1]));
      expect(f.endRead(b([9])), [
        b([1])
      ]);
      f.beginRead();
      f.onValue(b([2]));
      expect(f.endRead(null), [
        b([2])
      ]);
    });

    test('holds values until the last concurrent read ends', () {
      final f = ReadEchoFilter()
        ..beginRead()
        ..beginRead();
      f.onValue(b([1]));
      f.onValue(b([2]));
      f.onValue(b([3]));
      expect(f.endRead(b([2])), isEmpty);
      expect(f.endRead(b([3])), [
        b([1])
      ]);
      expect(f.onValue(b([4])), [
        b([4])
      ]);
    });
  });

  group('SerialQueue', () {
    test('a later operation waits for an earlier one in flight', () async {
      final q = SerialQueue();
      final log = <String>[];
      final gate = Completer<void>();
      final start = q.run(() async {
        log.add('start begins');
        await gate.future;
        log.add('start ends');
      });
      final stop = q.run(() async => log.add('stop'));
      await Future<void>.delayed(Duration.zero);
      expect(log, ['start begins']);
      gate.complete();
      await Future.wait([start, stop]);
      expect(log, ['start begins', 'start ends', 'stop']);
    });

    test('a failure is reported to its caller only', () async {
      final q = SerialQueue();
      final failed = q.run<void>(() async => throw StateError('x'));
      final next = q.run(() async => 42);
      await expectLater(failed, throwsStateError);
      expect(await next, 42);
    });
  });

  test('builds a scanResult event', () {
    final e = scanResultEvent(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'Sensor',
      rssi: -60,
      txPower: 0,
      manufacturerData: {
        0x004c: [1, 2]
      },
      serviceData: {
        '180d': [3]
      },
      serviceUuids: ['180d', custom.toUpperCase()],
    );
    expect(e['type'], 'scanResult');
    expect(e['id'], 'AA:BB:CC:DD:EE:FF');
    expect(e['name'], 'Sensor');
    expect(e['localName'], 'Sensor');
    expect(e['rssi'], -60);
    expect(e['connectable'], isTrue);
    expect(e['txPowerLevel'], isNull);
    expect(e['manufacturerData'], {
      0x004c: Uint8List.fromList([1, 2])
    });
    expect(e['manufacturerData'], isA<Map<int, Uint8List>>());
    expect(e['serviceData'], {
      hr: Uint8List.fromList([3])
    });
    expect(e['serviceUuids'], [hr, custom]);

    final withTx = scanResultEvent(
      id: 'x',
      name: null,
      rssi: -1,
      txPower: -8,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: const [],
    );
    expect(withTx['txPowerLevel'], -8);
    expect(withTx['name'], isNull);
  });

  group('errors', () {
    test('maps BlueZ error names to protocol codes', () {
      const cases = {
        'org.bluez.Error.NotConnected': 'not_connected',
        'org.bluez.Error.NotPermitted': 'permission_denied',
        'org.bluez.Error.NotAuthorized': 'permission_denied',
        'org.bluez.Error.NotSupported': 'not_supported',
        'org.bluez.Error.InProgress': 'busy',
        'org.bluez.Error.InvalidArguments': 'invalid_argument',
        'org.bluez.Error.InvalidValueLength': 'invalid_argument',
        'org.bluez.Error.DoesNotExist': 'not_found',
        'org.bluez.Error.NotReady': 'adapter_off',
        'org.bluez.Error.NoSuchAdapter': 'unavailable',
        // `unavailable` is reserved for "no Bluetooth".
        'org.bluez.Error.NotAvailable': 'gatt_error',
        'org.bluez.Error.Failed': 'gatt_error',
        'org.freedesktop.DBus.Error.NoReply': 'timeout',
        'org.freedesktop.DBus.Error.ServiceUnknown': 'unavailable',
        'something.Unexpected': 'gatt_error',
      };
      cases.forEach((name, code) {
        expect(errorCodeFor(name), code, reason: name);
      });
    });

    test('extracts the ATT status', () {
      final e = bleExceptionFor(
          'org.bluez.Error.Failed', 'Operation failed with ATT error: 0x0e');
      expect(e.code, 'gatt_error');
      expect(e.status, 0x0e);
      expect(e.message, contains('ATT error'));

      final plain = bleExceptionFor('org.bluez.Error.InProgress', '');
      expect(plain.code, 'busy');
      expect(plain.status, isNull);
      expect(plain.message, 'org.bluez.Error.InProgress');
    });

    test('maps D-Bus error responses', () {
      DBusMethodResponseException error(String name, [String? message]) =>
          DBusMethodResponseException(DBusMethodErrorResponse(
              name, [if (message != null) DBusString(message)]));

      final len = bleExceptionForError(
          error('org.bluez.Error.InvalidValueLength', 'Invalid Length'))!;
      expect(len.code, 'invalid_argument');
      expect(len.message, 'org.bluez.Error.InvalidValueLength: Invalid Length');

      final noReply =
          bleExceptionForError(error('org.freedesktop.DBus.Error.NoReply'))!;
      expect(noReply.code, 'timeout');
      expect(noReply.message, 'org.freedesktop.DBus.Error.NoReply');

      final att = bleExceptionForError(error(
          'org.bluez.Error.Failed', 'Operation failed with ATT error: 0x05'))!;
      expect(att.code, 'gatt_error');
      expect(att.status, 0x05);

      // package:bluez' own subclasses too.
      final bluez = bleExceptionForError(BlueZInProgressException(
          DBusMethodErrorResponse('org.bluez.Error.InProgress')))!;
      expect(bluez.code, 'busy');
    });

    test('maps pairing errors to bond_failed', () {
      const cases = {
        'org.bluez.Error.AuthenticationFailed': 'bond_failed',
        'org.bluez.Error.AuthenticationRejected': 'bond_failed',
        'org.bluez.Error.AuthenticationCanceled': 'bond_failed',
        'org.bluez.Error.AuthenticationTimeout': 'bond_failed',
        'org.bluez.Error.ConnectionAttemptFailed': 'bond_failed',
        'org.bluez.Error.Failed': 'bond_failed',
        'org.bluez.Error.InProgress': 'busy',
        'org.bluez.Error.NotReady': 'adapter_off',
        'org.bluez.Error.DoesNotExist': 'not_found',
      };
      cases.forEach((name, code) {
        expect(bondErrorCode(name), code, reason: name);
      });
      final e = bleExceptionForError(
          DBusMethodResponseException(DBusMethodErrorResponse(
              'org.bluez.Error.AuthenticationFailed',
              [const DBusString('Authentication Failed')])),
          bondErrorCode)!;
      expect(e.code, 'bond_failed');
      expect(e.message, contains('Authentication Failed'));
    });

    test('ignores errors that are not D-Bus responses', () {
      expect(bleExceptionForError(StateError('boom')), isNull);
      expect(bleExceptionForError(TimeoutException('t')), isNull);
      expect(bleExceptionForError('BlueZ device missing org.bluez.Device1'),
          isNull);
      expect(bleExceptionForError(const FormatException('a.b.c')), isNull);
      expect(bleExceptionForError(_FakeDBusError('org.bluez.Error.Failed')),
          isNull);
    });
  });

  test('without a system D-Bus everything reports unavailable', () async {
    final b = LinuxBleBackend();
    // Start-up calls (rule 17) answer before anything opens the bus.
    expect(await b.invoke('setLogLevel', {'level': 0}), isNull);
    expect(await b.invoke('stopScan', null), isNull);
    final events = <Map<String, dynamic>>[];
    b.events.listen(events.add);
    Matcher fails(String code) =>
        throwsA(isA<BleException>().having((e) => e.code, 'code', code));

    expect(await b.invoke('getAdapterState', null), 'unavailable');
    expect(await b.invoke('isSupported', null), isFalse);
    expect(await b.invoke('setOptions', {'showPowerAlert': true}), isFalse);
    expect(await b.invoke('getAdapterName', null), '');
    expect(await b.invoke('turnOff', null), isFalse);
    expect(await b.invoke('getPhySupport', null),
        {'le2M': false, 'leCoded': false});
    expect(await b.invoke('getBondedDevices', null), isEmpty);
    expect(await b.invoke('getSystemDevices', {'services': []}), isEmpty);
    expect(await b.invoke('getBondState', {'id': 'AA:BB:CC:DD:EE:FF'}), 'none');
    expect(await b.invoke('removeBond', {'id': 'AA:BB:CC:DD:EE:FF'}), isNull);
    expect(
        await b.invoke('clearGattCache', {'id': 'AA:BB:CC:DD:EE:FF'}), isNull);
    expect(
        await b.invoke('setPreferredPhy', {
          'id': 'AA:BB:CC:DD:EE:FF',
          'txPhy': 2,
          'rxPhy': 2,
          'codedOption': 0
        }),
        isNull);
    await expectLater(
      b.invoke('createBond', {'id': 'AA:BB:CC:DD:EE:FF', 'timeoutMs': 1000}),
      fails('unavailable'),
    );
    expect(await b.invoke('requestPermissions', null), isTrue);
    expect(await b.invoke('turnOn', null), isFalse);
    expect(await b.invoke('getConnectedDevices', null), isEmpty);
    expect(await b.invoke('stopScan', null), isNull);
    expect(await b.invoke('disconnect', {'id': 'AA:BB:CC:DD:EE:FF'}), isNull);
    await expectLater(
      b.invoke(
          'startScan', {'services': [], 'names': [], 'allowDuplicates': false}),
      fails('unavailable'),
    );
    await expectLater(
      b.invoke('startScan', {
        'services': ['not-a-uuid'],
        'names': [],
        'allowDuplicates': false
      }),
      fails('invalid_argument'),
    );
    await expectLater(
      b.invoke('connect', {'id': 'AA:BB:CC:DD:EE:FF', 'autoConnect': false}),
      fails('unavailable'),
    );
    await expectLater(
      b.invoke('read', {
        'id': 'AA:BB:CC:DD:EE:FF',
        'service': hr,
        'characteristic': '00002a37-0000-1000-8000-00805f9b34fb',
      }),
      fails('not_connected'),
    );
    expect(events, [
      {'type': 'adapterState', 'state': 'unavailable'},
    ]);

    await b.invoke('setLogLevel', {'level': 4});
    await expectLater(
      b.invoke('connect', {'id': 'AA:BB:CC:DD:EE:FF', 'autoConnect': false}),
      fails('unavailable'),
    );
    await Future<void>.delayed(Duration.zero);
    final logs = [
      for (final e in events)
        if (e['type'] == 'log') e
    ];
    expect(logs, isNotEmpty);
    expect(logs.every((e) => (e['level'] as int) <= 4), isTrue);
    expect(logs.last['message'], contains('connect failed'));
    await b.close();
  }, skip: Platform.isLinux ? 'needs a host without a system bus' : false);

  test('registerWith installs the Linux backend and replaces its own', () {
    final previous = BleChannel.backend;
    addTearDown(() => BleChannel.backend = previous);
    OpenBluePlusLinux.registerWith();
    final first = BleChannel.backend;
    expect(first, isA<LinuxBleBackend>());
    OpenBluePlusLinux.registerWith();
    expect(BleChannel.backend, isA<LinuxBleBackend>());
    expect(BleChannel.backend, isNot(same(first)));
  });
}

/// Looks like a D-Bus error when printed, but is not one.
class _FakeDBusError implements Exception {
  _FakeDBusError(this.text);
  final String text;

  @override
  String toString() => text;
}
