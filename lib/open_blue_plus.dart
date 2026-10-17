/// Bluetooth Low Energy (central role) for Flutter on Android, iOS, macOS,
/// Web, Linux and Windows.
library;

export 'src/device.dart' show BleDevice;
export 'src/events.dart' hide BleEventsInternal, newBleEvents;
export 'src/exception.dart';
export 'src/gatt.dart' hide GattDescriptorKeys, GattKeys, servicesFromMaps;
export 'src/log.dart' show BleLogLevel, BleLogRecord;
export 'src/manager.dart' hide recheckScanFilters;
export 'src/types.dart' hide bytesFrom, maskedPrefixMatch;
export 'src/uuid.dart';
