/// Error raised by any Bluetooth operation of this plugin.
class BleException implements Exception {
  /// Machine readable code, e.g. `timeout`, `not_connected`,
  /// `permission_denied`, `adapter_off`, `gatt_error`.
  final String code;

  /// Human readable description.
  final String? message;

  /// Platform status code, when the platform reported one.
  final int? status;

  /// Creates an exception with [code].
  const BleException(this.code, [this.message, this.status]);

  @override
  String toString() {
    final s = status == null ? '' : ' (status $status)';
    return 'BleException[$code]$s: ${message ?? ''}';
  }
}
