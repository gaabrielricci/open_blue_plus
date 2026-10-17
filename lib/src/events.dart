import 'dart:async';
import 'dart:typed_data';

import 'device.dart';
import 'gatt.dart';
import 'types.dart';
import 'uuid.dart';

/// A connection state change of [device].
class BleConnectionEvent {
  /// The device whose state changed.
  final BleDevice device;

  /// The new state.
  final DeviceConnectionState state;

  /// Set when [state] is `disconnected` and the platform gave a reason.
  final DisconnectReason? reason;

  /// Creates an event.
  const BleConnectionEvent(this.device, this.state, [this.reason]);
}

/// A new MTU on [device].
class BleMtuEvent {
  /// The device whose MTU changed.
  final BleDevice device;

  /// The new ATT MTU.
  final int mtu;

  /// Creates an event.
  const BleMtuEvent(this.device, this.mtu);
}

/// A characteristic value received from a read, a notification or an
/// indication.
class BleValueEvent {
  /// The device that sent the value.
  final BleDevice device;

  /// UUID of the characteristic's service.
  final BleUuid serviceUuid;

  /// See [BleService.index].
  final int serviceIndex;

  /// UUID of the characteristic.
  final BleUuid characteristicUuid;

  /// See [BleCharacteristic.index].
  final int characteristicIndex;

  /// The value.
  final Uint8List value;

  /// The matching characteristic, when services have been discovered.
  final BleCharacteristic? characteristic;

  /// Creates an event.
  const BleValueEvent(
      this.device,
      this.serviceUuid,
      this.serviceIndex,
      this.characteristicUuid,
      this.characteristicIndex,
      this.value,
      this.characteristic);
}

/// A successful write of [value] to [characteristic].
class BleWriteEvent {
  /// The characteristic written.
  final BleCharacteristic characteristic;

  /// The value written.
  final Uint8List value;

  /// Creates an event.
  const BleWriteEvent(this.characteristic, this.value);
}

/// A descriptor value read or written through the plugin.
class BleDescriptorEvent {
  /// The descriptor read or written.
  final BleDescriptor descriptor;

  /// The value read or written.
  final Uint8List value;

  /// Creates an event.
  const BleDescriptorEvent(this.descriptor, this.value);
}

/// A bond (pairing) state change of [device].
class BleBondEvent {
  /// The device whose bond state changed.
  final BleDevice device;

  /// The new bond state.
  final BondState state;

  /// The bond state before this change, if it was known.
  final BondState? previous;

  /// Creates an event.
  const BleBondEvent(this.device, this.state, this.previous);
}

/// [device] changed its name.
class BleNameEvent {
  /// The renamed device.
  final BleDevice device;

  /// The new name.
  final String name;

  /// Creates an event.
  const BleNameEvent(this.device, this.name);
}

/// The GATT database of [device] changed: call `discoverServices` again.
class BleServicesResetEvent {
  /// The device whose services changed.
  final BleDevice device;

  /// Creates an event.
  const BleServicesResetEvent(this.device);
}

/// The PHYs of the connection to [device] changed.
class BlePhyEvent {
  /// The device whose connection PHYs changed.
  final BleDevice device;

  /// The PHYs now in use.
  final PhyUpdate phy;

  /// Creates an event.
  const BlePhyEvent(this.device, this.phy);
}

/// Events of every device, in one place (`BleManager.instance.events`).
///
/// Useful to observe all devices without keeping per-device subscriptions.
/// Each stream is a broadcast stream that only emits future events.
class BleEvents {
  BleEvents._();

  final _connection = StreamController<BleConnectionEvent>.broadcast();
  final _mtu = StreamController<BleMtuEvent>.broadcast();
  final _value = StreamController<BleValueEvent>.broadcast();
  final _write = StreamController<BleWriteEvent>.broadcast();
  final _descriptor = StreamController<BleDescriptorEvent>.broadcast();
  final _bond = StreamController<BleBondEvent>.broadcast();
  final _name = StreamController<BleNameEvent>.broadcast();
  final _servicesReset = StreamController<BleServicesResetEvent>.broadcast();
  final _phy = StreamController<BlePhyEvent>.broadcast();

  /// Connection state changes (see [BleDevice.connectionState]).
  Stream<BleConnectionEvent> get onConnectionStateChanged => _connection.stream;

  /// MTU changes (see [BleDevice.onMtu]).
  Stream<BleMtuEvent> get onMtuChanged => _mtu.stream;

  /// Values from reads, notifications and indications (see
  /// [BleCharacteristic.onValue]).
  Stream<BleValueEvent> get onCharacteristicValue => _value.stream;

  /// Successful characteristic writes.
  Stream<BleWriteEvent> get onCharacteristicWritten => _write.stream;

  /// Descriptor values read or written (see [BleDescriptor.onValue]).
  Stream<BleDescriptorEvent> get onDescriptorValue => _descriptor.stream;

  /// Bond state changes (see [BleDevice.onBondState]).
  Stream<BleBondEvent> get onBondStateChanged => _bond.stream;

  /// Device name changes reported by the platform.
  Stream<BleNameEvent> get onNameChanged => _name.stream;

  /// GATT database changes (see [BleDevice.onServicesReset]).
  Stream<BleServicesResetEvent> get onServicesReset => _servicesReset.stream;

  /// PHY changes (see [BleDevice.onPhyChanged]).
  Stream<BlePhyEvent> get onPhyChanged => _phy.stream;
}

/// Creates the [BleEvents] of `BleManager` (not exported).
BleEvents newBleEvents() => BleEvents._();

/// Emitters used by [BleDevice] (not exported).
extension BleEventsInternal on BleEvents {
  void connection(BleConnectionEvent e) => _add(_connection, e);
  void mtu(BleMtuEvent e) => _add(_mtu, e);
  void value(BleValueEvent Function() e) {
    if (_value.hasListener) _value.add(e());
  }

  void write(BleWriteEvent e) => _add(_write, e);
  void descriptor(BleDescriptorEvent e) => _add(_descriptor, e);
  void bond(BleBondEvent e) => _add(_bond, e);
  void name(BleNameEvent e) => _add(_name, e);
  void servicesReset(BleServicesResetEvent e) => _add(_servicesReset, e);
  void phy(BlePhyEvent e) => _add(_phy, e);
}

void _add<T>(StreamController<T> c, T e) {
  if (c.hasListener) c.add(e);
}
