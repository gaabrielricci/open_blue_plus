// Recipe: pairing (bonding) across platforms.
//
// Android, Linux and Windows can pair on request, optionally supplying the
// PIN / passkey for you. iOS, macOS and Web pair automatically the first
// time an encrypted characteristic is read or written, so there the recipe
// just triggers that access.
import 'package:open_blue_plus/open_blue_plus.dart';

/// Makes sure [device] is paired. [pin]: PIN or passkey of devices that ask
/// for one (printers, locks...). [secured]: an encrypted characteristic to
/// read on platforms that pair on demand.
Future<void> ensurePaired(
  BleDevice device, {
  String? pin,
  BleCharacteristic? secured,
}) async {
  try {
    if (await device.bondState() == BondState.bonded) return;
    await device.createBond(pin: pin);
  } on BleException catch (e) {
    if (e.code != 'not_supported') rethrow;
    // iOS / macOS / Web: the OS shows its pairing dialog on first access.
    if (secured != null && secured.properties.read) await secured.read();
  }
}

/// Removes the pairing, ignoring platforms that do not allow it.
Future<void> forget(BleDevice device) async {
  try {
    await device.removeBond();
  } on BleException catch (e) {
    if (e.code != 'not_supported') rethrow;
  }
}
