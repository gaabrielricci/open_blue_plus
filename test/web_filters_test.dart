import 'dart:typed_data';

import 'package:open_blue_plus/platform_interface.dart';
import 'package:open_blue_plus/src/web/scan_filter.dart';
import 'package:flutter_test/flutter_test.dart';

const _hr = '0000180d-0000-1000-8000-00805f9b34fb';

void main() {
  test('no filter matches everything', () {
    final f = ScanFilter.fromArgs(const {});
    expect(f.hasNoLists, isTrue);
    expect(f.matches(id: 'a'), isTrue);
    expect(f.matchesChosen('a', null), isTrue);
  });

  test('lists are OR-ed, prefix is AND-ed', () {
    final f = ScanFilter.fromArgs({
      'services': ['180d'],
      'names': ['Polar H10'],
      'namePrefix': 'Po',
    });
    expect(f.services, [_hr]);
    expect(f.matches(id: 'a', name: 'Polar H10'), isTrue);
    expect(f.matches(id: 'a', name: 'Pod', serviceUuids: [_hr]), isTrue);
    expect(f.matches(id: 'a', name: 'Garmin', serviceUuids: [_hr]), isFalse);
    expect(f.matches(id: 'a', serviceUuids: [_hr]), isFalse);
    expect(f.matches(id: 'a', name: 'Pod'), isFalse);
  });

  test('keywords and remoteIds need an accept-all chooser', () {
    final f = ScanFilter.fromArgs({
      'keywords': ['Sensor'],
      'remoteIds': ['AbC='],
    });
    expect(f.needsAcceptAll, isTrue);
    expect(f.matchesChosen('AbC=', null), isTrue);
    expect(f.matchesChosen('abc=', 'x'), isFalse); // Web ids are case-sensitive
    expect(f.matchesChosen('x', 'My Sensor 2'), isTrue);
    expect(f.matchesChosen('x', 'my sensor'), isFalse);
    expect(f.matchesChosen('x', null), isNull);
  });

  test('chosen device is undecidable when advertisement data is needed', () {
    final f = ScanFilter.fromArgs({
      'keywords': ['Sensor'],
      'services': ['180d'],
    });
    expect(f.matchesChosen('x', 'Other'), isNull);
    final p = ScanFilter.fromArgs({
      'keywords': ['Sensor'],
      'namePrefix': 'My',
    });
    expect(p.matchesChosen('x', 'Your Sensor'), isFalse);
    expect(p.matchesChosen('x', null), isNull);
  });

  test('serviceData needs an accept-all chooser (Chromium ignores it)', () {
    final f = ScanFilter.fromArgs({
      'serviceData': [
        {'service': 'feaa', 'data': Uint8List(0)},
      ],
      'namePrefix': 'Ed',
    });
    expect(f.needsAcceptAll, isTrue);
    expect(f.matchesChosen('x', 'Eddy'), isNull);
    expect(f.matchesChosen('x', 'Other'), isFalse);
    expect(
        ScanFilter.fromArgs({
          'services': ['180d']
        }).needsAcceptAll,
        isFalse);
  });

  test('masked manufacturer and service data', () {
    final f = ScanFilter.fromArgs({
      'manufacturerData': [
        {
          'id': 0x004c,
          'data': Uint8List.fromList([0x02, 0x15]),
          'mask': Uint8List.fromList([0xff, 0x0f]),
        },
        {'id': 0x0059, 'data': Uint8List(0)},
      ],
      'serviceData': [
        {
          'service': 'feaa',
          'data': Uint8List.fromList([0x10]),
        },
      ],
    });
    bool mfr(int id, List<int> p) =>
        f.matches(id: 'a', manufacturerData: {id: Uint8List.fromList(p)});
    expect(mfr(0x004c, [0x02, 0x25, 0x99]), isTrue);
    expect(mfr(0x004c, [0x02, 0x26]), isFalse);
    expect(mfr(0x004c, [0x02]), isFalse);
    expect(mfr(0x0059, []), isTrue);
    expect(mfr(0x0001, [0x02, 0x15]), isFalse);
    final eddystone = '0000feaa-0000-1000-8000-00805f9b34fb';
    expect(
        f.matches(id: 'a', serviceData: {
          eddystone: Uint8List.fromList([0x10, 1])
        }),
        isTrue);
    expect(
        f.matches(id: 'a', serviceData: {
          eddystone: Uint8List.fromList([0])
        }),
        isFalse);
  });

  test('invalid UUIDs are invalid_argument', () {
    expect(
        () => ScanFilter.fromArgs({
              'services': ['xyz']
            }),
        throwsA(isA<BleException>()
            .having((e) => e.code, 'code', 'invalid_argument')));
  });
}
