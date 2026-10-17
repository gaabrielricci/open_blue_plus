import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'device.dart';
import 'exception.dart';
import 'streams.dart';
import 'types.dart';
import 'uuid.dart';

/// A GATT service discovered on a [BleDevice].
class BleService {
  /// The device exposing this service.
  final BleDevice device;

  /// The service UUID.
  final BleUuid uuid;

  /// Whether this is a primary service (secondary services are only reachable
  /// through [includedServices] of another service).
  final bool isPrimary;

  /// Position of this service among the services of [device] with the same
  /// [uuid] (0 unless the peripheral exposes the same service twice).
  final int index;

  /// The characteristics of this service, in the order of the platform.
  late final List<BleCharacteristic> characteristics;

  /// Services included by this one (they also appear on their own in
  /// [BleDevice.services]).
  late final List<BleService> includedServices;

  BleService._(this.device, this.uuid, this.isPrimary, this.index);

  /// Whether this is a secondary service.
  bool get isSecondary => !isPrimary;

  /// Returns the first characteristic with [uuid], or null.
  BleCharacteristic? characteristic(BleUuid uuid) {
    for (final c in characteristics) {
      if (c.uuid == uuid) return c;
    }
    return null;
  }

  @override
  String toString() =>
      'BleService($uuid${index == 0 ? '' : '#$index'}, ${characteristics.length} chars)';
}

/// Builds the services of [device] from the `discoverServices` result
/// (not exported).
List<BleService> servicesFromMaps(BleDevice device, List<Object?> raw) {
  final maps = [for (final m in raw) Map<String, dynamic>.from(m as Map)];
  final seen = <BleUuid, int>{};
  final services = <BleService>[];
  for (final m in maps) {
    final uuid = BleUuid(m['uuid'] as String);
    final index = seen[uuid] ?? 0;
    seen[uuid] = index + 1;
    final s =
        BleService._(device, uuid, (m['primary'] as bool?) ?? true, index);
    s.characteristics = BleCharacteristic._listFromMaps(
        s, (m['characteristics'] as List?) ?? const []);
    services.add(s);
  }
  for (var i = 0; i < services.length; i++) {
    final included = (maps[i]['included'] as List?) ?? const [];
    services[i].includedServices = [
      for (final p in included)
        if (p is int && p >= 0 && p < services.length && p != i) services[p],
    ];
  }
  return services;
}

/// A GATT characteristic.
class BleCharacteristic {
  /// The service containing this characteristic.
  final BleService service;

  /// The characteristic UUID.
  final BleUuid uuid;

  /// What the characteristic supports (read, write, notify...).
  final CharacteristicProperties properties;

  /// Position of this characteristic among the characteristics of [service]
  /// with the same [uuid] (0 unless the service has duplicates).
  final int index;

  /// The descriptors of this characteristic.
  late final List<BleDescriptor> descriptors;

  BleCharacteristic._(this.service, this.uuid, this.properties, this.index);

  static List<BleCharacteristic> _listFromMaps(
      BleService service, List<Object?> raw) {
    final seen = <BleUuid, int>{};
    return [
      for (final e in raw)
        () {
          final m = Map<String, dynamic>.from(e as Map);
          final uuid = BleUuid(m['uuid'] as String);
          final index = seen[uuid] ?? 0;
          seen[uuid] = index + 1;
          final c = BleCharacteristic._(
            service,
            uuid,
            CharacteristicProperties((m['properties'] as int?) ?? 0),
            index,
          );
          c.descriptors = [
            for (final d in (m['descriptors'] as List?) ?? const [])
              BleDescriptor._(c, BleUuid(d as String)),
          ];
          return c;
        }(),
    ];
  }

  /// The device exposing this characteristic.
  BleDevice get device => service.device;

  late final String _key =
      characteristicKey(service.uuid.value, service.index, uuid.value, index);

  Map<String, dynamic> get _args => {
        'id': device.id,
        'service': service.uuid.value,
        'serviceIndex': service.index,
        'characteristic': uuid.value,
        'characteristicIndex': index,
      };

  /// Last value read or received through a notification.
  Uint8List? get lastValue => device.lastValueOf(this);

  /// Values received from reads and notifications/indications.
  Stream<Uint8List> get onValue => device.valuesOf(this);

  /// Like [onValue], but first emits [lastValue] (when there is one).
  Stream<Uint8List> get lastValueStream =>
      currentThen(() => lastValue, onValue);

  /// Whether notifications or indications are enabled through this plugin.
  /// Reset when the device disconnects or its services change.
  bool get isNotifying => device.isNotifyingChar(this);

  /// Reads the current value.
  Future<Uint8List> read(
      {Duration timeout = const Duration(seconds: 15)}) async {
    final v = bytesFrom(
        await BleChannel.invokeWithTimeout<Object>('read', _args, timeout));
    device.handleReadResult(this, v);
    return v;
  }

  /// Longest value accepted by a write with response (ATT limit).
  static const int maxLongWriteLength = 512;

  /// Writes [value]. With [withoutResponse] the peripheral does not acknowledge
  /// the write; it is faster but delivery is not confirmed.
  ///
  /// Writes without response must fit in one packet (`device.mtu - 3`
  /// bytes); longer values fail with `invalid_argument` instead of being
  /// silently truncated by the platform. Writes with response may be longer
  /// than one packet (up to [maxLongWriteLength] bytes): the platform then
  /// uses a long (prepared) write, which the peripheral must support.
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final max = device.mtu - 3;
    if (withoutResponse && _mtuIsExact && value.length > max) {
      throw BleException('invalid_argument',
          'value has ${value.length} bytes but MTU ${device.mtu} allows $max without response');
    }
    if (!withoutResponse && value.length > maxLongWriteLength) {
      throw BleException('invalid_argument',
          'value has ${value.length} bytes; a write is limited to $maxLongWriteLength');
    }
    final bytes = Uint8List.fromList(value);
    await BleChannel.invokeWithTimeout<void>(
      'write',
      {..._args, 'value': bytes, 'withoutResponse': withoutResponse},
      timeout,
    );
    device.handleWritten(this, bytes);
  }

  /// Platforms that report the real MTU and silently truncate oversized
  /// writes without response. Elsewhere the reported MTU may be a placeholder.
  static bool get _mtuIsExact =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Enables or disables notifications (or indications, when the
  /// characteristic only supports those).
  ///
  /// [forceIndications] (Android, Windows): use indications even when
  /// notifications are supported. Other platforms let the OS choose.
  Future<void> setNotify(
    bool enable, {
    bool forceIndications = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await BleChannel.invokeWithTimeout<void>(
      'setNotify',
      {..._args, 'enable': enable, 'forceIndications': forceIndications},
      timeout,
    );
    device.handleNotifying(this, enable);
  }

  /// Returns the descriptor with [uuid], or null.
  BleDescriptor? descriptor(BleUuid uuid) {
    for (final d in descriptors) {
      if (d.uuid == uuid) return d;
    }
    return null;
  }

  @override
  String toString() =>
      'BleCharacteristic($uuid${index == 0 ? '' : '#$index'}, $properties)';
}

/// A GATT descriptor.
class BleDescriptor {
  /// The characteristic owning this descriptor.
  final BleCharacteristic characteristic;

  /// The descriptor UUID.
  final BleUuid uuid;

  BleDescriptor._(this.characteristic, this.uuid);

  /// The device exposing this descriptor.
  BleDevice get device => characteristic.device;

  late final String _key = '${characteristic._key}|${uuid.value}';

  Map<String, dynamic> get _args => {
        ...characteristic._args,
        'descriptor': uuid.value,
      };

  /// Last value read or written through this plugin.
  Uint8List? get lastValue => device.lastDescriptorValueOf(this);

  /// Values read or written through this plugin.
  Stream<Uint8List> get onValue => device.descriptorValuesOf(this);

  /// Reads the descriptor.
  Future<Uint8List> read(
      {Duration timeout = const Duration(seconds: 15)}) async {
    final v = bytesFrom(await BleChannel.invokeWithTimeout<Object>(
        'readDescriptor', _args, timeout));
    device.handleDescriptorValue(this, v);
    return v;
  }

  /// Writes the descriptor. Prefer [BleCharacteristic.setNotify] for the
  /// CCCD (0x2902); writing it is translated into `setNotify` on every
  /// platform except Web.
  Future<void> write(
    List<int> value, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final bytes = Uint8List.fromList(value);
    await BleChannel.invokeWithTimeout<void>(
      'writeDescriptor',
      {..._args, 'value': bytes},
      timeout,
    );
    device.handleDescriptorValue(this, bytes);
    if (uuid == BleUuids.cccd) {
      device.handleNotifying(characteristic, bytes.any((b) => b != 0));
    }
  }

  @override
  String toString() => 'BleDescriptor($uuid)';
}

/// Keys routing values to characteristics and descriptors (not exported).
extension GattKeys on BleCharacteristic {
  /// Key of this characteristic in [BleDevice]'s value maps.
  String get valueKey => _key;
}

/// See [GattKeys].
extension GattDescriptorKeys on BleDescriptor {
  /// Key of this descriptor in [BleDevice]'s value maps.
  String get valueKey => _key;
}
