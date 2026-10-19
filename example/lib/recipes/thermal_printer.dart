// Recipe: print a test page on a Bluetooth thermal printer (ESC/POS).
//
// Most cheap BLE receipt printers (MTP-2/3, PT-210, Goojprt, Xprinter...)
// expose one writable characteristic that accepts raw ESC/POS bytes. There
// is no standard service, so we try the common ones and fall back to any
// writable characteristic of a non-standard service.
//
// On Web, pass [printerServices] to `startScan(webOptionalServices: ...)`,
// otherwise the browser hides them after connecting.
import 'dart:async';
import 'dart:convert';

import 'package:open_blue_plus/open_blue_plus.dart';

/// Services used by common BLE thermal printers.
final printerServices = [
  BleUuid.short(0x18F0),
  BleUuid.short(0xFF00),
  BleUuid.short(0xFFE0),
  BleUuid('e7810a71-73ae-499d-8c15-faa9aef0c3f2'),
  BleUuid('49535343-fe7d-4ae5-8fa9-9fafd205e455'),
];

/// Returns the characteristic that receives print data, or null.
BleCharacteristic? findPrinterCharacteristic(BleDevice device) {
  bool writable(BleCharacteristic c) =>
      c.properties.write || c.properties.writeWithoutResponse;

  for (final uuid in printerServices) {
    final c = device.service(uuid)?.characteristics.where(writable);
    if (c != null && c.isNotEmpty) return c.first;
  }
  // Fallback: first writable characteristic outside the standard
  // Bluetooth SIG services (Generic Access, Device Information...).
  for (final s in device.services) {
    if (s.uuid.value.endsWith('-0000-1000-8000-00805f9b34fb') &&
        s.uuid.value.startsWith('00001')) {
      continue;
    }
    final c = s.characteristics.where(writable);
    if (c.isNotEmpty) return c.first;
  }
  return null;
}

/// ESC/POS bytes of a small test page (ASCII only: printers use their own
/// code page for accented characters).
///
/// With [cut], printers with a cutter (guillotine) cut the paper at the end;
/// printers without one ignore the command.
List<int> escPosTestPage({String title = 'open_blue_plus', bool cut = true}) {
  const esc = 0x1B, gs = 0x1D, lf = 0x0A;
  final now = DateTime.now().toString().substring(0, 19);
  return [
    esc, 0x40, // initialize
    esc, 0x61, 1, // center
    gs, 0x21, 0x11, // double width + height
    ...ascii.encode(title), lf,
    gs, 0x21, 0x00, // normal size
    ...ascii.encode('Bluetooth print test'), lf,
    ...ascii.encode('--------------------------------'), lf,
    esc, 0x61, 0, // left
    ...ascii.encode('Date: $now'), lf,
    esc, 0x45, 1, ...ascii.encode('Bold text'), esc, 0x45, 0, lf,
    ...ascii.encode('ABCDEFGHIJKLMNOPQRSTUVWXYZ'), lf,
    ...ascii.encode('0123456789 !@#\$%&*()-+=/'), lf,
    esc, 0x61, 1,
    ...ascii.encode('--------------------------------'), lf,
    ...ascii.encode('Printed with open_blue_plus'), lf,
    esc, 0x64, 4, // feed 4 lines
    if (cut) ...[gs, 0x56, 0x42, 0], // feed to the cutter, then full cut
  ];
}

/// Prints [escPosTestPage] on a connected [device] whose services were
/// discovered.
Future<void> printTestPage(BleDevice device, {bool cut = true}) async {
  final c = findPrinterCharacteristic(device);
  if (c == null) {
    throw const BleException('not_found', 'No printer characteristic found');
  }
  final data = escPosTestPage(cut: cut);
  // Writes with response are slower but never overflow the printer buffer.
  final withoutResponse = !c.properties.write;
  final chunk = device.mtu - 3;
  for (var i = 0; i < data.length; i += chunk) {
    final end = i + chunk < data.length ? i + chunk : data.length;
    await c.write(data.sublist(i, end), withoutResponse: withoutResponse);
    // Without response there is no flow control: give the printer time.
    if (withoutResponse) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
