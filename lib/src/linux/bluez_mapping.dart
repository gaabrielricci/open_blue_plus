import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../exception.dart';
import '../uuid.dart';

/// Pure conversions between BlueZ data and the backend protocol
/// (see `PROTOCOL.md`). Kept free of D-Bus calls so they can be unit tested.

/// Full 128-bit lowercase form of any UUID notation.
String fullUuid(String uuid) => BleUuid(uuid).value;

/// Same UUID regardless of notation or case.
bool sameUuid(String a, String b) => fullUuid(a) == fullUuid(b);

/// Protocol `properties` bit mask from the `Flags` of a
/// `org.bluez.GattCharacteristic1`.
int propertiesFromFlags(Iterable<String> flags) {
  var bits = 0;
  for (final f in flags) {
    bits |= switch (f) {
      'broadcast' => 0x01,
      'read' => 0x02,
      'write-without-response' => 0x04,
      'write' => 0x08,
      'notify' => 0x10,
      'indicate' => 0x20,
      'authenticated-signed-writes' => 0x40,
      // BlueZ splits extended properties into these flags.
      'extended-properties' ||
      'reliable-write' ||
      'writable-auxiliaries' =>
        0x80,
      _ => 0,
    };
  }
  return bits;
}

// ---- GATT database -----------------------------------------------------------

const gattServiceInterface = 'org.bluez.GattService1';
const gattCharacteristicInterface = 'org.bluez.GattCharacteristic1';
const gattDescriptorInterface = 'org.bluez.GattDescriptor1';

class GattDescriptorInfo {
  const GattDescriptorInfo(this.path, this.uuid);

  final String path;
  final String uuid;
}

class GattCharacteristicInfo {
  GattCharacteristicInfo({
    required this.path,
    required this.uuid,
    required this.properties,
    required this.descriptors,
    required this.mtu,
    required this.service,
    required this.serviceIndex,
    required this.index,
  });

  final String path;
  final String uuid;
  final int properties;
  final List<GattDescriptorInfo> descriptors;

  /// ATT MTU BlueZ reports for the bearer, null when absent.
  final int? mtu;

  /// UUID of the owning service and its protocol `serviceIndex`.
  final String service;
  final int serviceIndex;

  /// Protocol `characteristicIndex`.
  final int index;

  /// Fields of a `value` event for this characteristic, minus `value`.
  Map<String, Object?> valueEvent(String id) => {
        'type': 'value',
        'id': id,
        'service': service,
        'serviceIndex': serviceIndex,
        'characteristic': uuid,
        'characteristicIndex': index,
      };
}

class GattServiceInfo {
  GattServiceInfo({
    required this.path,
    required this.uuid,
    required this.primary,
    required this.included,
    required this.characteristics,
  });

  final String path;
  final String uuid;
  final bool primary;

  /// Positions of the included services in the discovery list.
  final List<int> included;
  final List<GattCharacteristicInfo> characteristics;
}

/// The `GattService1`/`GattCharacteristic1`/`GattDescriptor1` objects under
/// [prefix] in a `GetManagedObjects` result, in the shape [buildGattTree]
/// takes. `DBusValue.toNative` is not usable here: it returns arrays as lazy
/// iterables and object paths as [DBusObjectPath].
Map<String, Map<String, Map<String, Object?>>> gattObjectsFromDBus(
  Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> managed,
  String prefix,
) {
  Object? native(DBusValue v) => switch (v) {
        DBusObjectPath() => v.value,
        DBusArray() => [for (final c in v.children) native(c)],
        DBusVariant() => native(v.value),
        _ => v.toNative(),
      };
  return {
    for (final o in managed.entries)
      if (o.key.value.startsWith(prefix))
        o.key.value: {
          for (final i in o.value.entries)
            if (i.key.startsWith('org.bluez.Gatt'))
              i.key: {
                for (final p in i.value.entries)
                  // The cached value is not needed and can be large.
                  if (p.key != 'Value') p.key: native(p.value),
              },
        },
  };
}

/// The GATT database of one device from BlueZ objects (`path → interface →
/// property → native value`, as `DBusValue.toNative` returns them).
///
/// Every service, primary or secondary, appears once. Objects are ordered
/// by path: BlueZ names them `service%04x/char%04x/desc%04x` after the ATT
/// handle, so this is handle order and stays stable until the database
/// changes.
List<GattServiceInfo> buildGattTree(
    Map<String, Map<String, Map<String, Object?>>> objects) {
  final paths = objects.keys.toList()..sort();
  String parentOf(String path, Object? declared) =>
      declared is String ? declared : path.substring(0, path.lastIndexOf('/'));
  List<String> strings(Object? v) =>
      v is List ? [for (final e in v) '$e'] : const [];

  final descriptors = <String, List<GattDescriptorInfo>>{};
  final characteristics = <String, List<String>>{};
  final servicePaths = <String>[];
  for (final path in paths) {
    final o = objects[path]!;
    final desc = o[gattDescriptorInterface];
    if (desc != null) {
      (descriptors[parentOf(path, desc['Characteristic'])] ??= [])
          .add(GattDescriptorInfo(path, fullUuid('${desc['UUID']}')));
    }
    final char = o[gattCharacteristicInterface];
    if (char != null) {
      (characteristics[parentOf(path, char['Service'])] ??= []).add(path);
    }
    if (o.containsKey(gattServiceInterface)) servicePaths.add(path);
  }

  final position = {
    for (var i = 0; i < servicePaths.length; i++) servicePaths[i]: i,
  };
  final serviceCount = <String, int>{};
  return [
    for (final path in servicePaths)
      () {
        final svc = objects[path]![gattServiceInterface]!;
        final uuid = fullUuid('${svc['UUID']}');
        final serviceIndex = serviceCount[uuid] ?? 0;
        serviceCount[uuid] = serviceIndex + 1;
        final charCount = <String, int>{};
        return GattServiceInfo(
          path: path,
          uuid: uuid,
          primary: svc['Primary'] == true,
          included: [
            for (final p in strings(svc['Includes']))
              if (position[p] != null) position[p]!,
          ],
          characteristics: [
            for (final cp in characteristics[path] ?? const <String>[])
              () {
                final c = objects[cp]![gattCharacteristicInterface]!;
                final cu = fullUuid('${c['UUID']}');
                final index = charCount[cu] ?? 0;
                charCount[cu] = index + 1;
                final mtu = c['MTU'];
                return GattCharacteristicInfo(
                  path: cp,
                  uuid: cu,
                  properties: propertiesFromFlags(strings(c['Flags'])),
                  descriptors: descriptors[cp] ?? const [],
                  mtu: mtu is int && mtu > 0 ? mtu : null,
                  service: uuid,
                  serviceIndex: serviceIndex,
                  index: index,
                );
              }(),
          ],
        );
      }(),
  ];
}

/// One entry of the `discoverServices` result.
Map<String, Object?> serviceToMap(GattServiceInfo s) => {
      'uuid': s.uuid,
      'primary': s.primary,
      'included': s.included,
      'characteristics': [
        for (final c in s.characteristics)
          {
            'uuid': c.uuid,
            'properties': c.properties,
            'descriptors': [for (final d in c.descriptors) d.uuid],
          },
      ],
    };

/// The characteristic a protocol address
/// (`service`/`serviceIndex`/`characteristic`/`characteristicIndex`) points
/// to, or null.
GattCharacteristicInfo? findCharacteristic(
  List<GattServiceInfo> services,
  String service,
  int serviceIndex,
  String characteristic,
  int characteristicIndex,
) {
  final su = fullUuid(service);
  final cu = fullUuid(characteristic);
  var si = 0;
  for (final s in services) {
    if (s.uuid != su) continue;
    if (si++ != serviceIndex) continue;
    var ci = 0;
    for (final c in s.characteristics) {
      if (c.uuid == cu && ci++ == characteristicIndex) return c;
    }
    return null;
  }
  return null;
}

// ---- scanning ----------------------------------------------------------------

/// Payload [p] matches [data] under [mask] (null = all bits), see
/// `PROTOCOL.md` "Masked match".
bool maskedMatch(List<int> p, List<int> data, List<int>? mask) {
  if (p.length < data.length) return false;
  for (var i = 0; i < data.length; i++) {
    final m = mask == null || i >= mask.length ? 0xff : mask[i];
    if ((p[i] & m) != (data[i] & m)) return false;
  }
  return true;
}

typedef ManufacturerFilter = ({int id, List<int> data, List<int>? mask});
typedef ServiceDataFilter = ({String service, List<int> data, List<int>? mask});

/// The `startScan` filters, parsed once per scan. The six lists are
/// OR-combined (all empty = everything), `namePrefix` is AND-ed on top.
class ScanFilter {
  ScanFilter({
    this.services = const {},
    this.names = const [],
    this.keywords = const [],
    this.remoteIds = const {},
    this.manufacturerData = const [],
    this.serviceData = const [],
    this.namePrefix,
  });

  /// Throws [FormatException] for a malformed UUID.
  factory ScanFilter.fromArgs(Map<String, dynamic> a) {
    List<Object?> list(String key) => (a[key] as List?) ?? const [];
    List<int>? bytes(Object? v) => v == null ? null : List<int>.from(v as List);
    return ScanFilter(
      services: {for (final u in list('services')) fullUuid('$u')},
      names: [for (final n in list('names')) '$n'],
      keywords: [for (final k in list('keywords')) '$k'],
      remoteIds: {for (final r in list('remoteIds')) '$r'.toUpperCase()},
      manufacturerData: [
        for (final m in list('manufacturerData').cast<Map>())
          (
            id: m['id'] as int,
            data: bytes(m['data']) ?? const [],
            mask: bytes(m['mask']),
          ),
      ],
      serviceData: [
        for (final s in list('serviceData').cast<Map>())
          (
            service: fullUuid(s['service'] as String),
            data: bytes(s['data']) ?? const [],
            mask: bytes(s['mask']),
          ),
      ],
      namePrefix: a['namePrefix'] as String?,
    );
  }

  /// Full UUIDs.
  final Set<String> services;
  final List<String> names;
  final List<String> keywords;

  /// Upper-case.
  final Set<String> remoteIds;
  final List<ManufacturerFilter> manufacturerData;
  final List<ServiceDataFilter> serviceData;
  final String? namePrefix;

  bool get _noLists =>
      services.isEmpty &&
      names.isEmpty &&
      keywords.isEmpty &&
      remoteIds.isEmpty &&
      manufacturerData.isEmpty &&
      serviceData.isEmpty;

  /// UUIDs for BlueZ' `SetDiscoveryFilter`: only an exact pre-filter when
  /// services is the only list filter (BlueZ cannot OR it with others).
  List<String> get discoveryUuids => services.isNotEmpty &&
          names.isEmpty &&
          keywords.isEmpty &&
          remoteIds.isEmpty &&
          manufacturerData.isEmpty &&
          serviceData.isEmpty
      ? services.toList()
      : const [];

  /// Device properties the outcome depends on. A rejected device only needs
  /// a new check when one of these changes, not on every RSSI update.
  late final Set<String> relevantProperties = {
    if (names.isNotEmpty || keywords.isNotEmpty || namePrefix != null) 'Name',
    if (services.isNotEmpty) 'UUIDs',
    if (manufacturerData.isNotEmpty) 'ManufacturerData',
    if (serviceData.isNotEmpty) 'ServiceData',
  };

  /// [name] is `name ?? localName` (the same on BlueZ); [id] the address.
  bool matches({
    required String id,
    required String? name,
    required Iterable<String> serviceUuids,
    required Map<int, List<int>> manufacturerData,
    required Map<String, List<int>> serviceData,
  }) {
    final prefix = namePrefix;
    if (prefix != null && !(name ?? '').startsWith(prefix)) return false;
    if (_noLists) return true;
    if (name != null &&
        (names.contains(name) || keywords.any((k) => name.contains(k)))) {
      return true;
    }
    if (remoteIds.contains(id.toUpperCase())) return true;
    if (services.isNotEmpty &&
        serviceUuids.any((u) => services.contains(fullUuid(u)))) {
      return true;
    }
    for (final f in this.manufacturerData) {
      final p = manufacturerData[f.id];
      if (p != null && maskedMatch(p, f.data, f.mask)) return true;
    }
    if (this.serviceData.isNotEmpty) {
      for (final e in serviceData.entries) {
        final uuid = fullUuid(e.key);
        for (final f in this.serviceData) {
          if (f.service == uuid && maskedMatch(e.value, f.data, f.mask)) {
            return true;
          }
        }
      }
    }
    return false;
  }
}

/// `continuousDivisor`: reports the 1st advertisement of each device and
/// then every Nth one.
class ContinuousDivisor {
  ContinuousDivisor(this.divisor);

  final int divisor;
  final Map<String, int> _counts = {};

  bool shouldReport(String id) {
    final n = _counts[id] ?? 0;
    _counts[id] = n + 1;
    return n % divisor == 0;
  }
}

/// Whether a CCCD value enables notifications/indications (any non-zero
/// byte, as on the other platforms).
bool cccdEnables(List<int> value) => value.any((b) => b != 0);

/// The ATT MTU BlueZ reports on the characteristics of a device (all share
/// the bearer), or null while it is unknown.
int? knownMtu(Iterable<int?> characteristicMtus) {
  for (final m in characteristicMtus) {
    if (m != null && m > 0) return m;
  }
  return null;
}

/// Drops the `Value` change a `ReadValue` causes on a characteristic with
/// notifications on, so a read is reported once (by the read itself).
///
/// BlueZ updates the cached `Value` (and signals it) before replying to
/// `ReadValue`, so changes seen while a read is in flight are held; when the
/// read completes, the last held change equal to its result is its echo and
/// the rest are real notifications, released in order. Nothing is ever
/// dropped outside an in-flight read.
class ReadEchoFilter {
  int _reads = 0;
  final List<Uint8List> _held = [];

  /// A `Value` change: the values to emit now.
  List<Uint8List> onValue(Uint8List value) {
    if (_reads == 0) return [value];
    _held.add(value);
    return const [];
  }

  void beginRead() => _reads++;

  /// A read finished with [result] (null if it failed): the held values to
  /// emit now, before the read's own `value` event.
  List<Uint8List> endRead(Uint8List? result) {
    if (_reads > 0) _reads--;
    if (result != null) {
      for (var i = _held.length - 1; i >= 0; i--) {
        if (_sameBytes(_held[i], result)) {
          _held.removeAt(i);
          break;
        }
      }
    }
    if (_reads > 0) return const [];
    final out = List.of(_held);
    _held.clear();
    return out;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Runs asynchronous operations one at a time, in call order, so that e.g. a
/// `stopScan` cannot overtake a `startScan` still in flight.
class SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

/// `scanResult` event. BlueZ reports 0 for absent RSSI / TX power, so 0 TX
/// power is treated as unknown.
Map<String, Object?> scanResultEvent({
  required String id,
  required String? name,
  required int rssi,
  required int txPower,
  required Map<int, List<int>> manufacturerData,
  required Map<String, List<int>> serviceData,
  required Iterable<String> serviceUuids,
}) =>
    {
      'type': 'scanResult',
      'id': id,
      'name': name,
      'rssi': rssi,
      // BlueZ does not expose the advertising PDU type.
      'connectable': true,
      'localName': name,
      'txPowerLevel': txPower == 0 ? null : txPower,
      'manufacturerData': {
        for (final e in manufacturerData.entries)
          e.key: Uint8List.fromList(e.value),
      },
      'serviceData': {
        for (final e in serviceData.entries)
          fullUuid(e.key): Uint8List.fromList(e.value),
      },
      'serviceUuids': [for (final u in serviceUuids) fullUuid(u)],
    };

// ---- devices -------------------------------------------------------------------

/// `reason`/`reasonText` of a `Device1.Disconnected(reason, message)` signal
/// (BlueZ 5.82+). The reason names map to the HCI codes the other platforms
/// report; unknown ones keep only the text.
({int? code, String text}) disconnectReason(String reason, String message) {
  final code = switch (reason.substring(reason.lastIndexOf('.') + 1)) {
    'Timeout' => 0x08,
    'Remote' => 0x13,
    'Local' || 'Suspend' => 0x16,
    'Authentication' => 0x05,
    _ => null,
  };
  return (code: code, text: message.isEmpty ? reason : message);
}

/// Start time field of `/proc/self/stat` (with the pid, a key unique for the
/// lifetime of the system), or null if [stat] is malformed. The command name
/// in parentheses may itself contain spaces and parentheses.
String? procStartTime(String stat) {
  final end = stat.lastIndexOf(')');
  if (end < 0 || end + 2 > stat.length) return null;
  final fields = stat.substring(end + 2).split(' ');
  // Field 22 of the file; fields here start at field 3.
  return fields.length > 19 ? fields[19] : null;
}

// ---- errors --------------------------------------------------------------------

final _attError = RegExp(r'ATT error: 0x([0-9a-fA-F]+)');

String _shortName(String errorName) =>
    errorName.substring(errorName.lastIndexOf('.') + 1);

/// Protocol code for a D-Bus error name (`org.bluez.Error.*`).
String errorCodeFor(String errorName) {
  switch (_shortName(errorName)) {
    case 'NotConnected':
      return 'not_connected';
    case 'NotPermitted':
    case 'NotAuthorized':
    case 'AuthenticationFailed':
    case 'AuthenticationRejected':
    case 'AuthenticationCanceled':
    case 'AccessDenied':
      return 'permission_denied';
    case 'NotSupported':
      return 'not_supported';
    case 'InProgress':
      return 'busy';
    case 'InvalidArguments':
    case 'InvalidArgs':
    case 'InvalidValueLength':
    case 'InvalidOffset':
      return 'invalid_argument';
    case 'DoesNotExist':
    case 'UnknownObject':
    case 'UnknownMethod':
      return 'not_found';
    case 'NotReady':
      return 'adapter_off';
    // `unavailable` means no Bluetooth hardware/stack, nothing else.
    case 'NoSuchAdapter':
    case 'ServiceUnknown':
      return 'unavailable';
    case 'NoReply':
    case 'Timeout':
    case 'TimedOut':
    case 'AuthenticationTimeout':
      return 'timeout';
    case 'ConnectionAttemptFailed':
      return 'connect_failed';
    default:
      return 'gatt_error';
  }
}

/// Protocol code for a D-Bus error of `Device1.Pair` (or of the agent
/// registration it needs). `AlreadyExists` means already paired and is not
/// an error.
String bondErrorCode(String errorName) => switch (_shortName(errorName)) {
      'InProgress' => 'busy',
      'NotReady' => 'adapter_off',
      'DoesNotExist' || 'UnknownObject' => 'not_found',
      _ => 'bond_failed',
    };

/// [BleException] for a D-Bus error. The ATT status embedded in BlueZ
/// messages ("... ATT error: 0x0e") becomes [BleException.status].
BleException bleExceptionFor(String errorName, String message,
    [String Function(String) code = errorCodeFor]) {
  final att = _attError.firstMatch(message);
  return BleException(
    code(errorName),
    message.isEmpty ? errorName : '$errorName: $message',
    att == null ? null : int.parse(att.group(1)!, radix: 16),
  );
}

/// [BleException] for a D-Bus error response raised by package:bluez /
/// package:dbus (method calls and property writes alike), or null when
/// [error] is something else.
BleException? bleExceptionForError(Object error,
    [String Function(String) code = errorCodeFor]) {
  if (error is! DBusMethodResponseException) return null;
  final values = error.response.values;
  final message = values.isNotEmpty && values.first is DBusString
      ? values.first.asString()
      : '';
  return bleExceptionFor(error.errorName, message, code);
}
