import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// UUIDs matching the ESP32 NimBLE fan-controller sketch.
final Guid fanServiceUuid = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
final Guid commandCharUuid = Guid("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
final Guid statusCharUuid = Guid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");

const _appName = "SolderFan";
const _black = Color(0xFF070707);
const _panel = Color(0xFF121212);
const _panelAlt = Color(0xFF1A1A1A);
const _white = Color(0xFFF5F5F5);
const _muted = Color(0xFF9B9B9B);
const _red = Color(0xFFE11837);
const _deepRed = Color(0xFF7D0E1E);
const _tachMaxRpm = 2500;

void main() {
  runApp(const SolderFanApp());
}

class SolderFanApp extends StatelessWidget {
  const SolderFanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: _black,
        colorScheme: const ColorScheme.dark(
          primary: _red,
          secondary: _red,
          surface: _panel,
          error: _red,
          onPrimary: _white,
          onSecondary: _white,
          onSurface: _white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _black,
          foregroundColor: _white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: _white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _red,
            foregroundColor: _white,
            minimumSize: const Size(44, 40),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _white,
            side: const BorderSide(color: _red),
            minimumSize: const Size(44, 38),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: _red,
          inactiveTrackColor: Color(0xFF383838),
          thumbColor: _red,
          overlayColor: Color(0x33E11837),
          disabledActiveTrackColor: _deepRed,
          disabledInactiveTrackColor: Color(0xFF303030),
          disabledThumbColor: _red,
          trackHeight: 4,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? _white : _muted,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? _red
                : const Color(0xFF333333),
          ),
        ),
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: _white,
              displayColor: _white,
            ),
      ),
      home: const FanControlPage(),
    );
  }
}

class FanControlPage extends StatefulWidget {
  const FanControlPage({super.key});

  @override
  State<FanControlPage> createState() => _FanControlPageState();
}

class _FanControlPageState extends State<FanControlPage> {
  final List<ScanResult> _scanResults = [];
  final List<String> _log = [];

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandChar;

  bool _scanning = false;
  bool _connected = false;
  bool _autoMode = true;
  bool _draggingFan1 = false;
  bool _draggingFan2 = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  double _fan1 = 40;
  double _fan2 = 40;
  int _fan1Rpm = 0;
  int _fan2Rpm = 0;

  String _statusLine = "not connected";

  @override
  void initState() {
    super.initState();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _scanResults
          ..clear()
          ..addAll(results);
      });
    });
    _adapterStateSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _adapterState = state);
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _adapterState = BluetoothAdapterState.unavailable);
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _statusSub?.cancel();
    _connSub?.cancel();
    _adapterStateSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() {
      _log.insert(
          0, "${DateTime.now().toIso8601String().substring(11, 19)}  $s");
      if (_log.length > 12) _log.removeLast();
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    }
  }

  Future<BluetoothAdapterState> _waitForBluetoothReady() async {
    bool supported = false;
    try {
      supported = await FlutterBluePlus.isSupported;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    }
    if (!supported) return BluetoothAdapterState.unavailable;

    var state = BluetoothAdapterState.unknown;
    try {
      state = await FlutterBluePlus.adapterState.first;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    }
    if (state == BluetoothAdapterState.unknown) {
      try {
        state = await FlutterBluePlus.adapterState
            .where((value) => value != BluetoothAdapterState.unknown)
            .first
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _adapterState = state);
    }
    return state;
  }

  String _adapterStateText(BluetoothAdapterState state) {
    switch (state) {
      case BluetoothAdapterState.on:
        return "on";
      case BluetoothAdapterState.off:
        return "off";
      case BluetoothAdapterState.turningOn:
        return "turning on";
      case BluetoothAdapterState.turningOff:
        return "turning off";
      case BluetoothAdapterState.unavailable:
        return "unavailable";
      case BluetoothAdapterState.unauthorized:
        return "unauthorized";
      case BluetoothAdapterState.unknown:
        return "unknown";
    }
  }

  Future<void> _startScan() async {
    await _requestPermissions();

    final adapterState = await _waitForBluetoothReady();
    if (adapterState != BluetoothAdapterState.on) {
      final stateText = _adapterStateText(adapterState);
      setState(() => _statusLine = "Bluetooth adapter is $stateText");
      _addLog("bluetooth adapter is $stateText");
      return;
    }

    setState(() {
      _scanResults.clear();
      _scanning = true;
    });

    _addLog("scan started");

    try {
      await FlutterBluePlus.startScan(
        withServices: [fanServiceUuid],
        timeout: const Duration(seconds: 6),
      );
    } catch (e) {
      _addLog("scan error: $e");
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
        _addLog("scan stopped");
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    final label = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.toString();
    _addLog("connecting to $label");

    try {
      await FlutterBluePlus.stopScan();
      if (mounted) setState(() => _scanning = false);

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (!mounted) return;
        setState(
            () => _connected = state == BluetoothConnectionState.connected);
        _addLog("connection: $state");
      });

      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
        license: License.nonprofit,
      );

      final services = await device.discoverServices();
      BluetoothCharacteristic? command;
      BluetoothCharacteristic? status;

      for (final s in services) {
        if (s.uuid == fanServiceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == commandCharUuid) command = c;
            if (c.uuid == statusCharUuid) status = c;
          }
        }
      }

      if (command == null || status == null) {
        throw Exception(
            "fan BLE service found, but command/status characteristics are missing");
      }

      _device = device;
      _commandChar = command;

      await status.setNotifyValue(true);
      await _statusSub?.cancel();
      _statusSub = status.onValueReceived.listen((value) {
        _handleStatusLine(utf8.decode(value, allowMalformed: true));
      });

      await _send("STATUS");
      _addLog("connected and ready");
      if (mounted) setState(() => _connected = true);
    } catch (e) {
      _addLog("connect error: $e");
      try {
        await device.disconnect();
      } catch (_) {}
      if (mounted) setState(() => _connected = false);
    }
  }

  void _handleStatusLine(String text) {
    final telemetry = _FanTelemetry.tryParse(text);
    setState(() {
      _statusLine = text;
      if (telemetry == null) return;

      _fan1Rpm = telemetry.fan1Rpm;
      _fan2Rpm = telemetry.fan2Rpm;
      _autoMode = telemetry.autoMode;

      if (!_draggingFan1 || telemetry.autoMode) {
        _fan1 = telemetry.fan1Duty.toDouble();
      }
      if (!_draggingFan2 || telemetry.autoMode) {
        _fan2 = telemetry.fan2Duty.toDouble();
      }
    });
  }

  Future<void> _disconnect() async {
    await _statusSub?.cancel();
    _statusSub = null;
    await _connSub?.cancel();
    _connSub = null;

    try {
      await _device?.disconnect();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _device = null;
      _commandChar = null;
      _connected = false;
      _fan1Rpm = 0;
      _fan2Rpm = 0;
      _statusLine = "not connected";
    });
  }

  Future<void> _send(String command) async {
    final c = _commandChar;
    if (c == null) {
      _addLog("not connected");
      return;
    }

    try {
      await c.write(utf8.encode(command), withoutResponse: false);
      _addLog("sent: $command");
    } catch (e) {
      _addLog("write error: $e");
    }
  }

  Future<void> _setAutoMode(bool enabled) async {
    setState(() => _autoMode = enabled);
    if (enabled) {
      await _send("AUTO");
    } else {
      await _send("BOTH ${_fan1.round()}");
      if (_fan1.round() != _fan2.round()) {
        await _send("MAN 2 ${_fan2.round()}");
      }
    }
  }

  Future<void> _sendFan1() => _send("MAN 1 ${_fan1.round()}");
  Future<void> _sendFan2() => _send("MAN 2 ${_fan2.round()}");
  Future<void> _sendBoth() => _send("BOTH ${((_fan1 + _fan2) / 2).round()}");

  @override
  Widget build(BuildContext context) {
    final connectedName = _device?.platformName ?? "";
    final connectedLabel =
        connectedName.isNotEmpty ? connectedName : _device?.remoteId.toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text(_appName),
        actions: [
          IconButton(
            tooltip: _connected ? "Disconnect" : "Scan",
            onPressed:
                _connected ? _disconnect : (_scanning ? null : _startScan),
            icon: Icon(_connected
                ? Icons.bluetooth_disabled
                : Icons.bluetooth_searching),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final content = [
              _ConnectionPanel(
                connected: _connected,
                scanning: _scanning,
                adapterState: _adapterStateText(_adapterState),
                label: connectedLabel,
                results: _scanResults,
                onScan: _startScan,
                onConnect: _connect,
              ),
              _GaugeStrip(
                fan1Rpm: _fan1Rpm,
                fan2Rpm: _fan2Rpm,
                fan1Duty: _fan1.round(),
                fan2Duty: _fan2.round(),
              ),
              _ControlPanel(
                connected: _connected,
                autoMode: _autoMode,
                fan1: _fan1,
                fan2: _fan2,
                onAutoModeChanged: _setAutoMode,
                onFan1Changed: (value) => setState(() => _fan1 = value),
                onFan2Changed: (value) => setState(() => _fan2 = value),
                onFan1ChangeStart: (_) => setState(() => _draggingFan1 = true),
                onFan2ChangeStart: (_) => setState(() => _draggingFan2 = true),
                onFan1ChangeEnd: (_) async {
                  setState(() => _draggingFan1 = false);
                  await _sendFan1();
                },
                onFan2ChangeEnd: (_) async {
                  setState(() => _draggingFan2 = false);
                  await _sendFan2();
                },
                onBothFull: () => _send("BOTH 100"),
                onBothAverage: _sendBoth,
              ),
              _StatusPanel(statusLine: _statusLine, log: _log),
            ];

            return ListView(
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 20 : 12,
                vertical: 10,
              ),
              children: content
                  .map((widget) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: widget,
                      ))
                  .toList(),
            );
          },
        ),
      ),
    );
  }
}

class _FanTelemetry {
  final int fan1Duty;
  final int fan1Rpm;
  final int fan2Duty;
  final int fan2Rpm;
  final bool autoMode;

  const _FanTelemetry({
    required this.fan1Duty,
    required this.fan1Rpm,
    required this.fan2Duty,
    required this.fan2Rpm,
    required this.autoMode,
  });

  static _FanTelemetry? tryParse(String line) {
    final values = <String, String>{};
    for (final part in line.split(',')) {
      final pieces = part.split('=');
      if (pieces.length != 2) continue;
      values[pieces[0].trim()] = pieces[1].trim();
    }

    final fan1Duty = int.tryParse(values['fan1_duty'] ?? '');
    final fan1Rpm = int.tryParse(values['fan1_rpm'] ?? '');
    final fan2Duty = int.tryParse(values['fan2_duty'] ?? '');
    final fan2Rpm = int.tryParse(values['fan2_rpm'] ?? '');
    final mode = values['mode'];

    if (fan1Duty == null ||
        fan1Rpm == null ||
        fan2Duty == null ||
        fan2Rpm == null ||
        mode == null) {
      return null;
    }

    return _FanTelemetry(
      fan1Duty: fan1Duty.clamp(0, 100).toInt(),
      fan1Rpm: fan1Rpm,
      fan2Duty: fan2Duty.clamp(0, 100).toInt(),
      fan2Rpm: fan2Rpm,
      autoMode: mode == 'auto',
    );
  }
}

class _ConnectionPanel extends StatelessWidget {
  final bool connected;
  final bool scanning;
  final String adapterState;
  final String? label;
  final List<ScanResult> results;
  final VoidCallback onScan;
  final ValueChanged<BluetoothDevice> onConnect;

  const _ConnectionPanel({
    required this.connected,
    required this.scanning,
    required this.adapterState,
    required this.label,
    required this.results,
    required this.onScan,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: connected ? _red : _muted,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? (label ?? "connected") : "not connected",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      "Bluetooth: $adapterState",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: _muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: scanning ? null : onScan,
                icon: scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search, size: 18),
                label: Text(scanning ? "Scanning" : "Scan $_appName"),
              ),
            ],
          ),
          if (results.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFF2B2B2B)),
            ...results.take(4).map((r) {
              final name = r.device.platformName;
              final deviceLabel =
                  name.isNotEmpty ? name : r.device.remoteId.toString();
              return ListTile(
                dense: true,
                minVerticalPadding: 0,
                contentPadding: EdgeInsets.zero,
                title: Text(deviceLabel,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text("RSSI ${r.rssi}",
                    style: const TextStyle(color: _muted)),
                trailing: const Icon(Icons.chevron_right, color: _red),
                onTap: () => onConnect(r.device),
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _GaugeStrip extends StatelessWidget {
  final int fan1Rpm;
  final int fan2Rpm;
  final int fan1Duty;
  final int fan2Duty;

  const _GaugeStrip({
    required this.fan1Rpm,
    required this.fan2Rpm,
    required this.fan1Duty,
    required this.fan2Duty,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _TachGauge(
            label: "Fan 1",
            rpm: fan1Rpm,
            duty: fan1Duty,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _TachGauge(
            label: "Fan 2",
            rpm: fan2Rpm,
            duty: fan2Duty,
          ),
        ),
      ],
    );
  }
}

class _TachGauge extends StatelessWidget {
  final String label;
  final int rpm;
  final int duty;

  const _TachGauge({
    required this.label,
    required this.rpm,
    required this.duty,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                    fontSize: 13, color: _muted, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                "$duty%",
                style: const TextStyle(
                    fontSize: 13, color: _red, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 78,
            child: CustomPaint(
              painter: _GaugePainter(value: rpm, maxValue: _tachMaxRpm),
              child: const _GaugeScaleLabels(),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                rpm.toString(),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const SizedBox(width: 5),
              const Padding(
                padding: EdgeInsets.only(bottom: 1),
                child: Text(
                  "RPM",
                  style: TextStyle(
                      fontSize: 10, color: _muted, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugeScaleLabels extends StatelessWidget {
  const _GaugeScaleLabels();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        Positioned(
          left: 0,
          bottom: 0,
          child: Text(
            "0",
            style: TextStyle(
                color: _muted, fontSize: 9, fontWeight: FontWeight.w700),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Text(
            "2500",
            style: TextStyle(
                color: _muted, fontSize: 9, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  final int value;
  final int maxValue;

  const _GaugePainter({
    required this.value,
    required this.maxValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.92);
    final radius = math.min(size.width * 0.42, size.height * 0.88);
    const startAngle = math.pi * 1.12;
    const sweepAngle = math.pi * 0.76;
    final progress = (value / maxValue).clamp(0.0, 1.0);
    final needleAngle = startAngle + sweepAngle * progress;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final basePaint = Paint()
      ..color = const Color(0xFF3A3A3A)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8;

    final redPaint = Paint()
      ..color = _red
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8;

    canvas.drawArc(rect, startAngle, sweepAngle, false, basePaint);
    canvas.drawArc(rect, startAngle, sweepAngle * progress, false, redPaint);

    final tickPaint = Paint()
      ..color = _white
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.2;

    for (var i = 0; i <= 6; i++) {
      final angle = startAngle + sweepAngle * (i / 6);
      final outer = Offset(
        center.dx + math.cos(angle) * (radius + 1),
        center.dy + math.sin(angle) * (radius + 1),
      );
      final inner = Offset(
        center.dx + math.cos(angle) * (radius - (i.isEven ? 13 : 9)),
        center.dy + math.sin(angle) * (radius - (i.isEven ? 13 : 9)),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }

    final needleEnd = Offset(
      center.dx + math.cos(needleAngle) * (radius - 18),
      center.dy + math.sin(needleAngle) * (radius - 18),
    );
    final needlePaint = Paint()
      ..color = _white
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;

    canvas.drawLine(center, needleEnd, needlePaint);
    canvas.drawCircle(center, 5.5, Paint()..color = _red);
    canvas.drawCircle(center, 2.5, Paint()..color = _white);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return value != oldDelegate.value || maxValue != oldDelegate.maxValue;
  }
}

class _ControlPanel extends StatelessWidget {
  final bool connected;
  final bool autoMode;
  final double fan1;
  final double fan2;
  final ValueChanged<bool> onAutoModeChanged;
  final ValueChanged<double> onFan1Changed;
  final ValueChanged<double> onFan2Changed;
  final ValueChanged<double> onFan1ChangeStart;
  final ValueChanged<double> onFan2ChangeStart;
  final ValueChanged<double> onFan1ChangeEnd;
  final ValueChanged<double> onFan2ChangeEnd;
  final VoidCallback onBothFull;
  final VoidCallback onBothAverage;

  const _ControlPanel({
    required this.connected,
    required this.autoMode,
    required this.fan1,
    required this.fan2,
    required this.onAutoModeChanged,
    required this.onFan1Changed,
    required this.onFan2Changed,
    required this.onFan1ChangeStart,
    required this.onFan2ChangeStart,
    required this.onFan1ChangeEnd,
    required this.onFan2ChangeEnd,
    required this.onBothFull,
    required this.onBothAverage,
  });

  @override
  Widget build(BuildContext context) {
    final manualEnabled = connected && !autoMode;

    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.tune, color: _red, size: 21),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  "Potentiometer mode",
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Switch(
                value: autoMode,
                onChanged: connected ? onAutoModeChanged : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          _FanSlider(
            label: "Fan 1",
            value: fan1,
            enabled: manualEnabled,
            onChanged: onFan1Changed,
            onChangeStart: onFan1ChangeStart,
            onChangeEnd: onFan1ChangeEnd,
          ),
          _FanSlider(
            label: "Fan 2",
            value: fan2,
            enabled: manualEnabled,
            onChanged: onFan2Changed,
            onChangeStart: onFan2ChangeStart,
            onChangeEnd: onFan2ChangeEnd,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: manualEnabled ? onBothFull : null,
                  icon: const Icon(Icons.speed, size: 18),
                  label: const Text("100%"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: manualEnabled ? onBothAverage : null,
                  icon: const Icon(Icons.sync_alt, size: 18),
                  label: const Text("Average"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FanSlider extends StatelessWidget {
  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChangeEnd;

  const _FanSlider({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(
              "${value.round()} %",
              style: const TextStyle(color: _red, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        SizedBox(
          height: 34,
          child: Slider(
            min: 0,
            max: 100,
            divisions: 100,
            value: value.clamp(0.0, 100.0).toDouble(),
            onChanged: enabled ? onChanged : null,
            onChangeStart: enabled ? onChangeStart : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  final String statusLine;
  final List<String> log;

  const _StatusPanel({
    required this.statusLine,
    required this.log,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Status",
            style: TextStyle(
                fontSize: 13, color: _muted, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            statusLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: "monospace", fontSize: 12),
          ),
          if (log.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFF2B2B2B)),
            const SizedBox(height: 6),
            ...log.take(5).map(
                  (line) => Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: "monospace", fontSize: 11, color: _muted),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_panelAlt, _panel],
            ),
          ),
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}
