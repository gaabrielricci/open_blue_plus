import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_blue_plus/open_blue_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apple options must be set before any other Bluetooth call.
  await ble.setOptions(showPowerAlert: true);
  if (kDebugMode) await ble.setLogLevel(BleLogLevel.info);
  runApp(const ExampleApp());
}

final ble = BleManager.instance;

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'open_blue_plus',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ScanPage(),
    );
  }
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

List<int> parseHex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return [
    for (var i = 0; i + 1 < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
}

// ---------------------------------------------------------------------------

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _keyword = TextEditingController();

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    ble.requestPermissions().catchError((Object e) {
      if (mounted) showError(context, e);
      return false;
    });
  }

  Future<void> _toggleScan(bool scanning) async {
    try {
      if (scanning) {
        await ble.stopScan();
      } else {
        final keyword = _keyword.text.trim();
        await ble.startScan(
          withKeywords: keyword.isEmpty ? const [] : [keyword],
          timeout: const Duration(seconds: 15),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE devices'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(76),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _keyword,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.filter_alt_outlined),
                    hintText: 'Name contains... (optional)',
                  ),
                ),
              ),
              StreamBuilder<AdapterState>(
                stream: ble.adapterState,
                builder: (context, snap) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('Adapter: ${snap.data?.name ?? '...'}'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: StreamBuilder<List<ScanResult>>(
        stream: ble.scanResults,
        builder: (context, snap) {
          final results = snap.data ?? const [];
          if (results.isEmpty) {
            return const Center(child: Text('No devices yet. Tap scan.'));
          }
          return ListView.separated(
            itemCount: results.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = results[i];
              final name = r.advertisement.localName ?? r.device.name;
              return ListTile(
                title: Text(name?.isNotEmpty == true ? name! : '(no name)'),
                subtitle: Text(r.device.id),
                trailing: Text('${r.rssi} dBm'),
                enabled: r.advertisement.connectable,
                onTap: () async {
                  try {
                    await ble.stopScan();
                  } catch (_) {
                    // Opening the device page matters more than the scan.
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DevicePage(device: r.device, title: name),
                  ));
                },
              );
            },
          );
        },
      ),
      floatingActionButton: StreamBuilder<bool>(
        stream: ble.isScanning,
        builder: (context, snap) {
          final scanning = snap.data ?? false;
          return FloatingActionButton.extended(
            onPressed: () => _toggleScan(scanning),
            icon: Icon(scanning ? Icons.stop : Icons.search),
            label: Text(scanning ? 'Stop' : 'Scan'),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class DevicePage extends StatefulWidget {
  final BleDevice device;
  final String? title;

  const DevicePage({super.key, required this.device, this.title});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  BleDevice get device => widget.device;
  bool _busy = false;
  StreamSubscription<void>? _resetSub;

  @override
  void initState() {
    super.initState();
    // The peripheral changed its services: discover them again.
    _resetSub = device.onServicesReset.listen((_) {
      if (device.isConnected) _run(() => device.discoverServices());
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
        await device.connect();
        await device.discoverServices();
      });

  Future<void> _menu(String action) => _run(() async {
        switch (action) {
          case 'pair':
            await device.createBond();
          case 'unpair':
            await device.removeBond();
          case 'rssi':
            final rssi = await device.readRssi();
            if (mounted) showError(context, 'RSSI: $rssi dBm');
          case 'cache':
            await device.clearGattCache();
            await device.discoverServices();
        }
      });

  @override
  void dispose() {
    _resetSub?.cancel();
    device.disconnect().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.title?.isNotEmpty == true ? widget.title! : device.id),
        actions: [
          StreamBuilder<DeviceConnectionState>(
            stream: device.connectionState,
            builder: (context, snap) {
              final connected = snap.data == DeviceConnectionState.connected;
              return TextButton(
                onPressed: _busy
                    ? null
                    : connected
                        ? () => _run(device.disconnect)
                        : _connect,
                child: Text(connected ? 'DISCONNECT' : 'CONNECT'),
              );
            },
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pair', child: Text('Pair')),
              PopupMenuItem(value: 'unpair', child: Text('Unpair')),
              PopupMenuItem(value: 'rssi', child: Text('Read RSSI')),
              PopupMenuItem(value: 'cache', child: Text('Clear GATT cache')),
            ],
          ),
        ],
      ),
      body: StreamBuilder<DeviceConnectionState>(
        stream: device.connectionState,
        builder: (context, snap) {
          final state = snap.data ?? DeviceConnectionState.disconnected;
          return ListView(
            children: [
              ListTile(
                title: Text('State: ${state.name}'),
                subtitle: StreamBuilder<int>(
                  stream: device.onMtu,
                  builder: (_, m) => Text('MTU: ${m.data ?? device.mtu}'),
                ),
                trailing: _busy ? const CircularProgressIndicator() : null,
              ),
              if (state == DeviceConnectionState.disconnected &&
                  device.disconnectReason?.code != null)
                ListTile(
                  dense: true,
                  title: Text('Last disconnection: ${device.disconnectReason}'),
                ),
              StreamBuilder<BondState>(
                stream: device.onBondState,
                builder: (_, b) => b.hasData
                    ? ListTile(
                        dense: true, title: Text('Bond: ${b.data!.name}'))
                    : const SizedBox.shrink(),
              ),
              if (state == DeviceConnectionState.connected)
                for (final s in device.services)
                  ServiceTile(key: ObjectKey(s), service: s),
            ],
          );
        },
      ),
    );
  }
}

class ServiceTile extends StatelessWidget {
  final BleService service;
  const ServiceTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(
          '${service.isPrimary ? 'Service' : 'Secondary service'} ${service.uuid}'),
      children: [
        // Keyed by object: after a rediscovery each tile must listen to its
        // new characteristic, not keep the state of the old one.
        for (final c in service.characteristics)
          CharacteristicTile(key: ObjectKey(c), characteristic: c),
      ],
    );
  }
}

class CharacteristicTile extends StatefulWidget {
  final BleCharacteristic characteristic;
  const CharacteristicTile({super.key, required this.characteristic});

  @override
  State<CharacteristicTile> createState() => _CharacteristicTileState();
}

class _CharacteristicTileState extends State<CharacteristicTile> {
  BleCharacteristic get c => widget.characteristic;
  StreamSubscription<List<int>>? _sub;
  List<int>? _value;

  @override
  void initState() {
    super.initState();
    _value = c.lastValue;
    _sub = c.onValue.listen((v) => setState(() => _value = v));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _write() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Write (hex)'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '01 02 ff'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Write'),
          ),
        ],
      ),
    );
    if (input == null) return;
    await _guard(() => c.write(
          parseHex(input),
          withoutResponse:
              !c.properties.write && c.properties.writeWithoutResponse,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final p = c.properties;
    return ListTile(
      title: Text('Char ${c.uuid}'),
      subtitle: Text('$p\n${_value == null ? '-' : hex(_value!)}'),
      isThreeLine: true,
      trailing: Wrap(
        children: [
          if (p.read)
            IconButton(
              tooltip: 'Read',
              icon: const Icon(Icons.download),
              onPressed: () => _guard(() => c.read()),
            ),
          if (p.write || p.writeWithoutResponse)
            IconButton(
                tooltip: 'Write',
                icon: const Icon(Icons.upload),
                onPressed: _write),
          if (p.notify || p.indicate)
            IconButton(
              tooltip: 'Notify',
              icon: Icon(c.isNotifying
                  ? Icons.notifications_active
                  : Icons.notifications_none),
              onPressed: () => _guard(() async {
                await c.setNotify(!c.isNotifying);
                if (mounted) setState(() {});
              }),
            ),
        ],
      ),
    );
  }
}
