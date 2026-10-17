// Recipe: iBeacon scanner with live RSSI.
//
// Uses a manufacturer data filter (Apple company id 0x004C, iBeacon prefix
// 02 15), duplicate advertisements for live RSSI, and `removeIfGone` to drop
// beacons that went silent. Works on Android, Linux and Windows. iOS hides
// iBeacon advertisements from CoreBluetooth (use CoreLocation there), and Web
// can only pick one device through the browser chooser.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:open_blue_plus/open_blue_plus.dart';

/// A decoded iBeacon advertisement.
class IBeacon {
  final String uuid;
  final int major;
  final int minor;

  /// Calibrated RSSI at 1 m, as advertised.
  final int txPower;
  final int rssi;

  const IBeacon(this.uuid, this.major, this.minor, this.txPower, this.rssi);

  /// Rough distance estimate in meters (log-distance path loss, n = 2).
  double get distance => math.pow(10, (txPower - rssi) / 20).toDouble();

  /// Parses the Apple manufacturer payload (without the company id).
  static IBeacon? parse(Uint8List p, int rssi) {
    if (p.length < 23 || p[0] != 0x02 || p[1] != 0x15) return null;
    String h(int i) => p[i].toRadixString(16).padLeft(2, '0');
    final hex = [for (var i = 2; i < 18; i++) h(i)].join();
    final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return IBeacon(uuid, (p[18] << 8) | p[19], (p[20] << 8) | p[21],
        p[22].toSigned(8), rssi);
  }
}

/// Emits the list of iBeacons in range, refreshed on every advertisement.
/// Stops scanning when the returned stream is cancelled.
Stream<List<IBeacon>> scanBeacons() {
  final ble = BleManager.instance;
  late final StreamController<List<IBeacon>> out;
  StreamSubscription<List<ScanResult>>? sub;
  out = StreamController<List<IBeacon>>(
    onListen: () async {
      sub = ble.scanResults.listen((results) {
        out.add([
          for (final r in results)
            if (IBeacon.parse(
                    r.advertisement.manufacturerData[0x004C] ?? Uint8List(0),
                    r.rssi)
                case final b?)
              b,
        ]);
      });
      try {
        await ble.startScan(
          withManufacturerData: [
            const ManufacturerDataFilter(0x004C, data: [0x02, 0x15]),
          ],
          allowDuplicates: true,
          continuousDivisor: 2,
          removeIfGone: const Duration(seconds: 10),
          androidScanMode: AndroidScanMode.lowLatency,
        );
      } catch (e, st) {
        out.addError(e, st);
      }
    },
    onCancel: () async {
      await sub?.cancel();
      await ble.stopScan();
    },
  );
  return out.stream;
}
