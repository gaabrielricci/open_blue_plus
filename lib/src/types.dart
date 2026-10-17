import 'dart:typed_data';

import 'device.dart';
import 'uuid.dart';

/// State of the local Bluetooth adapter.
enum AdapterState {
  /// Not known yet.
  unknown,

  /// No Bluetooth LE hardware (or no Web Bluetooth API).
  unavailable,

  /// The app is not allowed to use Bluetooth.
  unauthorized,

  /// Turning on.
  turningOn,

  /// On and usable.
  on,

  /// Turning off.
  turningOff,

  /// Off.
  off;

  /// Parses a protocol value; unknown values give [unknown].
  static AdapterState parse(String? s) => AdapterState.values
      .firstWhere((v) => v.name == s, orElse: () => AdapterState.unknown);
}

/// Connection state of a [BleDevice].
enum DeviceConnectionState {
  /// Not connected.
  disconnected,

  /// `connect` is in progress.
  connecting,

  /// Connected.
  connected,

  /// `disconnect` is in progress.
  disconnecting,
}

/// Pairing (bonding) state of a device. Android, Linux and Windows report
/// it; other platforms return [unknown].
enum BondState {
  /// Not paired.
  none,

  /// Pairing in progress.
  bonding,

  /// Paired.
  bonded,

  /// The platform does not tell.
  unknown;

  /// Parses a protocol value; unknown values give [unknown].
  static BondState parse(String? s) => BondState.values
      .firstWhere((v) => v.name == s, orElse: () => BondState.unknown);
}

/// Android scan modes. Ignored on other platforms.
enum AndroidScanMode {
  /// Least power, slowest discovery.
  lowPower(0),

  /// Balance between power and latency.
  balanced(1),

  /// Fastest discovery, most power (use while the app is in the foreground).
  lowLatency(2);

  /// Protocol value.
  final int code;
  const AndroidScanMode(this.code);
}

/// Android connection priorities. Ignored on other platforms.
enum ConnectionPriority {
  /// Default connection interval.
  balanced(0),

  /// Short connection interval: faster transfers, more power.
  high(1),

  /// Long connection interval: slower, saves power.
  lowPower(2);

  /// Protocol value.
  final int code;
  const ConnectionPriority(this.code);
}

/// Scan filter on manufacturer specific data.
///
/// Matches when the device advertises data for [companyId] whose payload
/// (without the 2 company id bytes) starts with [data], comparing only the
/// bits set in [mask] (all bits when [mask] is null). An empty [data] matches
/// any payload of that company.
class ManufacturerDataFilter {
  /// Bluetooth SIG company identifier (16 bits).
  final int companyId;

  /// Expected payload prefix (bytes).
  final List<int> data;

  /// Bits of [data] to compare, same length as [data]; null compares all.
  final List<int>? mask;

  /// Creates a filter (checked when the scan starts).
  const ManufacturerDataFilter(this.companyId,
      {this.data = const [], this.mask});

  void _check() {
    if (companyId < 0 || companyId > 0xFFFF) {
      throw ArgumentError.value(
          companyId, 'companyId', 'must be a 16-bit value');
    }
    _checkMask(data, mask);
  }

  /// Protocol representation. Throws [ArgumentError] when invalid.
  Map<String, Object?> toMap() {
    _check();
    return {
      'id': companyId,
      'data': Uint8List.fromList(data),
      'mask': mask == null ? null : Uint8List.fromList(mask!),
    };
  }

  /// Whether [adv] matches this filter.
  bool matches(AdvertisementData adv) {
    final p = adv.manufacturerData[companyId];
    return p != null && maskedPrefixMatch(p, data, mask);
  }
}

/// Scan filter on service data. Same matching rules as
/// [ManufacturerDataFilter], for the payload advertised for [service].
class ServiceDataFilter {
  /// Service whose data is matched.
  final BleUuid service;

  /// Expected payload prefix (bytes).
  final List<int> data;

  /// Bits of [data] to compare, same length as [data]; null compares all.
  final List<int>? mask;

  /// Creates a filter (checked when the scan starts).
  const ServiceDataFilter(this.service, {this.data = const [], this.mask});

  /// Protocol representation. Throws [ArgumentError] when invalid.
  Map<String, Object?> toMap() {
    _checkMask(data, mask);
    return {
      'service': service.value,
      'data': Uint8List.fromList(data),
      'mask': mask == null ? null : Uint8List.fromList(mask!),
    };
  }

  /// Whether [adv] matches this filter.
  bool matches(AdvertisementData adv) {
    final p = adv.serviceData[service];
    return p != null && maskedPrefixMatch(p, data, mask);
  }
}

void _checkMask(List<int> data, List<int>? mask) {
  if (mask != null && mask.length != data.length) {
    throw ArgumentError.value(
        mask, 'mask', 'must have the same length as data');
  }
}

/// `payload` starts with [data] under [mask] (see [ManufacturerDataFilter]).
bool maskedPrefixMatch(List<int> payload, List<int> data, List<int>? mask) {
  if (payload.length < data.length) return false;
  for (var i = 0; i < data.length; i++) {
    final m = mask == null ? 0xFF : mask[i];
    if ((payload[i] & m) != (data[i] & m)) return false;
  }
  return true;
}

/// A Bluetooth LE physical layer.
enum BlePhy {
  /// LE 1M, supported by every device.
  le1m(1),

  /// LE 2M: twice the data rate (Bluetooth 5).
  le2m(2),

  /// LE Coded: long range (Bluetooth 5).
  leCoded(4);

  /// Bit used in `setPreferredPhy` masks.
  final int mask;
  const BlePhy(this.mask);

  /// Protocol mask of [phys].
  static int maskOf(Set<BlePhy> phys) => phys.fold(0, (m, p) => m | p.mask);

  /// Parses the value of a `phy` event (1 = 1M, 2 = 2M, 3 = Coded).
  static BlePhy? fromEvent(int? v) => switch (v) {
        1 => le1m,
        2 => le2m,
        3 => leCoded,
        _ => null,
      };
}

/// Coding preferred for the LE Coded PHY (long range).
enum PhyCodedOption {
  /// No preference.
  none(0),

  /// S=2 coding (500 kbit/s).
  s2(1),

  /// S=8 coding (125 kbit/s, longest range).
  s8(2);

  /// Protocol value.
  final int code;
  const PhyCodedOption(this.code);
}

/// PHYs supported by the local adapter.
class PhySupport {
  /// LE 2M PHY (faster).
  final bool le2m;

  /// LE Coded PHY (long range).
  final bool leCoded;

  /// Creates a value.
  const PhySupport({required this.le2m, required this.leCoded});

  @override
  String toString() => 'PhySupport(le2m: $le2m, leCoded: $leCoded)';
}

/// PHYs in use on a connection, reported after `setPreferredPhy`.
class PhyUpdate {
  /// Transmitter PHY (null if the platform sent an unknown value).
  final BlePhy? tx;

  /// Receiver PHY (null if the platform sent an unknown value).
  final BlePhy? rx;

  /// Creates a value.
  const PhyUpdate(this.tx, this.rx);

  @override
  String toString() => 'PhyUpdate(tx: ${tx?.name}, rx: ${rx?.name})';
}

/// Why a device disconnected, as reported by the platform.
class DisconnectReason {
  /// Platform code: Android GATT status (e.g. 0x08 supervision timeout,
  /// 0x13 remote terminated, 0x16 local host, 133 error), Apple `NSError.code`,
  /// BlueZ reason. Null when the platform does not say.
  final int? code;

  /// Human readable description, when available.
  final String? description;

  /// When the disconnection was observed.
  final DateTime time;

  /// Creates a reason observed now.
  DisconnectReason(this.code, this.description) : time = DateTime.now();

  @override
  String toString() =>
      'DisconnectReason($code${description == null ? '' : ', $description'})';
}

/// Data broadcast by a peripheral while advertising.
class AdvertisementData {
  /// Local name in the advertisement or scan response, if any.
  final String? localName;

  /// Advertised transmit power in dBm, if any.
  final int? txPowerLevel;

  /// Whether the peripheral accepts connections.
  final bool connectable;

  /// Company identifier -> payload (without the 2 company id bytes).
  final Map<int, Uint8List> manufacturerData;

  /// Service UUID -> service data payload.
  final Map<BleUuid, Uint8List> serviceData;

  /// Advertised service UUIDs.
  final List<BleUuid> serviceUuids;

  /// Creates advertisement data.
  const AdvertisementData({
    this.localName,
    this.txPowerLevel,
    this.connectable = true,
    this.manufacturerData = const {},
    this.serviceData = const {},
    this.serviceUuids = const [],
  });

  /// Parses a protocol `scanResult` event.
  factory AdvertisementData.fromMap(Map<String, dynamic> m) {
    final manu = <int, Uint8List>{};
    (m['manufacturerData'] as Map?)?.forEach((k, v) {
      manu[k is int ? k : int.parse('$k')] = _bytes(v);
    });
    final svc = <BleUuid, Uint8List>{};
    (m['serviceData'] as Map?)?.forEach((k, v) {
      svc[BleUuid(k as String)] = _bytes(v);
    });
    return AdvertisementData(
      localName: m['localName'] as String?,
      txPowerLevel: m['txPowerLevel'] as int?,
      connectable: (m['connectable'] as bool?) ?? true,
      manufacturerData: manu,
      serviceData: svc,
      serviceUuids: ((m['serviceUuids'] as List?) ?? const [])
          .map((e) => BleUuid(e as String))
          .toList(),
    );
  }
}

/// One advertisement received while scanning.
class ScanResult {
  /// The advertising device.
  final BleDevice device;

  /// Signal strength in dBm.
  final int rssi;

  /// The advertised data.
  final AdvertisementData advertisement;

  /// When the advertisement was received.
  final DateTime timestamp;

  /// Creates a result.
  const ScanResult({
    required this.device,
    required this.rssi,
    required this.advertisement,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ScanResult(${device.id}, ${advertisement.localName ?? device.name}, rssi $rssi)';
}

/// GATT characteristic properties (Bluetooth Core spec bit layout, identical
/// on every platform).
class CharacteristicProperties {
  /// The property bits.
  final int raw;

  /// Wraps [raw] property bits.
  const CharacteristicProperties(this.raw);

  /// 0x01: the value may be broadcast.
  bool get broadcast => raw & 0x01 != 0;

  /// 0x02: readable.
  bool get read => raw & 0x02 != 0;

  /// 0x04: writable without response.
  bool get writeWithoutResponse => raw & 0x04 != 0;

  /// 0x08: writable with response.
  bool get write => raw & 0x08 != 0;

  /// 0x10: supports notifications.
  bool get notify => raw & 0x10 != 0;

  /// 0x20: supports indications.
  bool get indicate => raw & 0x20 != 0;

  /// 0x40: supports authenticated signed writes.
  bool get authenticatedSignedWrites => raw & 0x40 != 0;

  /// 0x80: has extended properties.
  bool get extendedProperties => raw & 0x80 != 0;

  @override
  String toString() {
    final names = <String>[
      if (read) 'read',
      if (write) 'write',
      if (writeWithoutResponse) 'writeNoResp',
      if (notify) 'notify',
      if (indicate) 'indicate',
      if (broadcast) 'broadcast',
    ];
    return names.join(', ');
  }
}

Uint8List _bytes(Object? v) {
  if (v is Uint8List) return v;
  if (v is List) return Uint8List.fromList(v.cast<int>());
  return Uint8List(0);
}

/// Converts a value from the platform channel into bytes.
Uint8List bytesFrom(Object? v) => _bytes(v);
