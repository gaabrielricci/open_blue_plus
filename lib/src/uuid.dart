/// A Bluetooth UUID, always stored in its full 128-bit lowercase form.
///
/// Accepts 16-bit (`"180d"`), 32-bit (`"0000180d"`) and 128-bit
/// (`"0000180d-0000-1000-8000-00805f9b34fb"`) notations.
class BleUuid {
  static const String _baseSuffix = '-0000-1000-8000-00805f9b34fb';
  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  /// Full 128-bit lowercase representation.
  final String value;

  const BleUuid._(this.value);

  /// Parses [input]; throws [FormatException] if it is not a UUID.
  factory BleUuid(String input) {
    final s = input.trim().toLowerCase();
    final hex = s.replaceAll('-', '');
    if (!_hex.hasMatch(hex)) {
      throw FormatException('Invalid Bluetooth UUID', input);
    }
    switch (hex.length) {
      case 4:
        return BleUuid._('0000$hex$_baseSuffix');
      case 8:
        return BleUuid._('$hex$_baseSuffix');
      case 32:
        return BleUuid._('${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
            '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}');
      default:
        throw FormatException('Invalid Bluetooth UUID length', input);
    }
  }

  /// Creates a UUID from a 16-bit assigned number, e.g. `BleUuid.short(0x180D)`.
  factory BleUuid.short(int assigned) =>
      BleUuid(assigned.toRadixString(16).padLeft(4, '0'));

  /// Whether this UUID belongs to the Bluetooth SIG base range.
  bool get isSigAssigned => value.endsWith(_baseSuffix);

  /// The shortest notation: 4 hex digits for SIG UUIDs with a 16-bit value,
  /// otherwise the full 128-bit string.
  String get shortString {
    if (isSigAssigned && value.startsWith('0000')) return value.substring(4, 8);
    if (isSigAssigned) return value.substring(0, 8);
    return value;
  }

  @override
  bool operator ==(Object other) => other is BleUuid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => shortString;
}

/// Commonly used UUIDs.
class BleUuids {
  BleUuids._();

  /// Client Characteristic Configuration Descriptor.
  static final BleUuid cccd = BleUuid.short(0x2902);

  /// Serial Port Profile (0x1101): on Android, the service and the
  /// characteristic that carry a Bluetooth Classic SPP link (see
  /// `BleDevice.connect`, `transport`).
  static final BleUuid serialPort = BleUuid.short(0x1101);
}
