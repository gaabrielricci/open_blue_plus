// Pure Dart (no web imports) so it can be unit tested on the VM.
import 'dart:typed_data';

import '../exception.dart';
import '../uuid.dart';

/// One `manufacturerData` / `serviceData` entry of a scan filter.
class DataFilter {
  const DataFilter(this.key, this.data, this.mask);

  /// Company id (int) or service UUID (String).
  final Object key;
  final Uint8List data;
  final Uint8List? mask;

  /// Masked prefix match of `PROTOCOL.md`.
  bool matches(Uint8List payload) {
    final d = data, m = mask;
    if (payload.length < d.length) return false;
    for (var i = 0; i < d.length; i++) {
      final mi = m == null || i >= m.length ? 0xFF : m[i];
      if ((payload[i] & mi) != (d[i] & mi)) return false;
    }
    return true;
  }
}

/// The filtering arguments of `startScan`.
class ScanFilter {
  ScanFilter({
    this.services = const [],
    this.names = const [],
    this.keywords = const [],
    this.remoteIds = const [],
    this.manufacturerData = const [],
    this.serviceData = const [],
    this.namePrefix,
  });

  factory ScanFilter.fromArgs(Map<String, dynamic> a) {
    List<String> strings(String k) =>
        [for (final s in (a[k] as List?) ?? const []) s as String];
    final prefix = a['namePrefix'] as String?;
    return ScanFilter(
      services: [for (final s in strings('services')) uuid(s)],
      names: strings('names'),
      keywords: strings('keywords'),
      remoteIds: strings('remoteIds'),
      manufacturerData: [
        for (final m in (a['manufacturerData'] as List?) ?? const [])
          _data(m as Map, (m['id'] as num).toInt()),
      ],
      serviceData: [
        for (final m in (a['serviceData'] as List?) ?? const [])
          _data(m as Map, uuid(m['service'] as String)),
      ],
      namePrefix: prefix == null || prefix.isEmpty ? null : prefix,
    );
  }

  static DataFilter _data(Map m, Object key) {
    Uint8List? bytes(Object? v) => v == null
        ? null
        : v is Uint8List
            ? v
            : Uint8List.fromList((v as List).cast<int>());
    return DataFilter(key, bytes(m['data']) ?? Uint8List(0), bytes(m['mask']));
  }

  /// Full 128-bit lowercase form, as the browser reports UUIDs.
  static String uuid(String s) {
    try {
      return BleUuid(s).value;
    } on FormatException catch (e) {
      throw BleException('invalid_argument', '${e.message}: $s');
    }
  }

  final List<String> services;
  final List<String> names;
  final List<String> keywords;
  final List<String> remoteIds;
  final List<DataFilter> manufacturerData;
  final List<DataFilter> serviceData;
  final String? namePrefix;

  /// No OR-list is set (every device passes them).
  bool get hasNoLists =>
      services.isEmpty &&
      names.isEmpty &&
      keywords.isEmpty &&
      remoteIds.isEmpty &&
      manufacturerData.isEmpty &&
      serviceData.isEmpty;

  /// `keywords` and `remoteIds` cannot be expressed as chooser filters, nor
  /// can `serviceData`: Chromium ignores that member, which leaves an empty
  /// filter object (TypeError for the whole call) or a bare `namePrefix`.
  bool get needsAcceptAll =>
      keywords.isNotEmpty || remoteIds.isNotEmpty || serviceData.isNotEmpty;

  /// Whether an advertisement matches. [name] is `name ?? localName`.
  bool matches({
    required String id,
    String? name,
    List<String> serviceUuids = const [],
    Map<int, Uint8List> manufacturerData = const {},
    Map<String, Uint8List> serviceData = const {},
  }) {
    final prefix = namePrefix;
    if (prefix != null && !(name ?? '').startsWith(prefix)) return false;
    if (hasNoLists) return true;
    if (_matchesIdOrName(id, name)) return true;
    for (final s in services) {
      if (serviceUuids.contains(s)) return true;
    }
    for (final f in this.manufacturerData) {
      final p = manufacturerData[f.key];
      if (p != null && f.matches(p)) return true;
    }
    for (final f in this.serviceData) {
      final p = serviceData[f.key];
      if (p != null && f.matches(p)) return true;
    }
    return false;
  }

  /// Checks a device picked in an accept-all chooser, of which only [id] and
  /// [name] are known. `null` = undecidable until an advertisement arrives.
  bool? matchesChosen(String id, String? name) {
    final prefix = namePrefix;
    if (prefix != null) {
      if (name == null) return null;
      if (!name.startsWith(prefix)) return false;
    }
    if (hasNoLists || _matchesIdOrName(id, name)) return true;
    final unknown = services.isNotEmpty ||
        manufacturerData.isNotEmpty ||
        serviceData.isNotEmpty ||
        (name == null && (names.isNotEmpty || keywords.isNotEmpty));
    return unknown ? null : false;
  }

  /// Web ids are opaque and compared case-sensitively.
  bool _matchesIdOrName(String id, String? name) {
    if (remoteIds.contains(id)) return true;
    if (name == null) return false;
    if (names.contains(name)) return true;
    for (final k in keywords) {
      if (name.contains(k)) return true;
    }
    return false;
  }
}
