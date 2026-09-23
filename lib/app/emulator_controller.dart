import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../can/fault_injector.dart';
import '../can/periodic_traffic.dart';
import '../can/virtual_can_bus.dart';
import '../ecu/dtc.dart';
import '../ecu/ecu.dart';
import '../ecu/ecu_profile.dart';
import '../elm327/elm_session.dart';
import '../elm327/elm_state.dart';
import '../transport/tcp_transport.dart';
import '../transport/transport.dart';
import '../transport/transport_bridge.dart';
import '../util/hex.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';
import 'emulation_core.dart';

enum LogKind { input, output, can, fault, info }

class LogEntry {
  LogEntry(this.time, this.kind, this.text);
  final DateTime time;
  final LogKind kind;
  final String text;
}

enum DtcKind { confirmed, pending, permanent }

/// Flutter 側の結線。接続ごとに ElmSession を持ち、UI からの操作を中核へ渡す。
class EmulatorController extends ChangeNotifier {
  EmulatorController({
    TransportBridge? bridge,
    EmulationCore? core,
    bool? tcpAvailable,
  }) : bridge = bridge ?? TransportBridge(),
       core = core ?? EmulationCore(),
       _tcpAvailable = tcpAvailable ?? (!kIsWeb && Platform.isMacOS);

  final EmulationCore core;
  final TransportBridge bridge;
  final TcpTransport tcp = TcpTransport();
  final bool _tcpAvailable;

  static const maxLog = 2000;

  List<TransportType> caps = [];
  final Map<TransportType, String> connState = {};
  final Map<TransportType, ElmSession> sessions = {};
  final List<LogEntry> log = [];
  bool useFff0 = false;
  TransportType? _lastActive;
  final ElmState _idleState = ElmState();
  Timer? _tick;
  void Function()? _unlistenBus;
  final List<StreamSubscription<Object?>> _subs = [];

  VehicleState get vehicle => core.vehicle;
  Simulator get simulator => core.simulator;

  /// 接続タブに出す ELM の状態（最後に受信した接続のもの）。
  ElmState get displayState => sessions[_lastActive]?.state ?? _idleState;

  List<TransportType> get connectedTransports => [
    for (final e in connState.entries)
      if (e.value.startsWith('接続中')) e.key,
  ];

  String get headlineStatus {
    final c = connectedTransports;
    return c.isEmpty ? '未接続' : '${c.first.label} 接続中';
  }

  String statusText(TransportType t) => connState[t] ?? '停止中';

  Future<void> init() async {
    core.start();
    caps = [
      ...await bridge.capabilities(),
      if (_tcpAvailable) TransportType.tcp,
    ];
    _subs
      ..add(bridge.onReceive.listen((e) => _receive(e.transport, e.bytes)))
      ..add(
        bridge.onConnection.listen(
          (e) => _onConnection(e.transport, e.state, e.device),
        ),
      )
      ..add(tcp.onReceive.listen((b) => _receive(TransportType.tcp, b)))
      ..add(
        tcp.onConnection.listen((s) {
          final parts = s.split(' ');
          _onConnection(
            TransportType.tcp,
            parts.first,
            parts.length > 1 ? parts[1] : '',
          );
        }),
      );
    _unlistenBus = core.bus.listen(_onBus);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      core.simulator.tick(0.2);
      notifyListeners();
    });
    notifyListeners();
  }

  ElmSession _sessionFor(TransportType t) => sessions.putIfAbsent(t, () {
    final s = core.newSession();
    s.output.listen((bytes) {
      _log(LogKind.output, _escape(bytes));
      if (t == TransportType.tcp) {
        tcp.send(bytes);
      } else {
        bridge.send(t, bytes);
      }
    });
    return s;
  });

  void _receive(TransportType t, List<int> bytes) {
    _lastActive = t;
    _log(LogKind.input, _escape(bytes));
    _sessionFor(t).input(bytes);
  }

  void _onConnection(TransportType t, String state, String device) {
    if (state == 'connected') {
      connState[t] = device.isEmpty ? '接続中' : '接続中 · $device';
    } else {
      // 停止済み（stopBle/stopSpp で connState[t] が消えている）のに遅れて届いた
      // disconnected イベントでは、待ち受け中と誤表示しない。
      if (connState.containsKey(t)) {
        connState[t] = '待ち受け中';
      }
      sessions.remove(t)?.dispose();
    }
    _log(LogKind.info, '[${t.label}] $state $device'.trim());
  }

  bool _isDiagnostic(int id, bool extended) =>
      extended ||
      (id >= 0x7DF && id <= 0x7EF) ||
      !PeriodicTraffic.ids.contains(id);

  void _onBus(BusEvent e) {
    final f = e.frame;
    if (!_isDiagnostic(f.id, f.extended)) return;
    _log(LogKind.can, '${e.sender is Ecu ? 'RX' : 'TX'} $f');
  }

  static String _escape(List<int> bytes) => String.fromCharCodes(
    bytes,
  ).replaceAll('\r', r'\r').replaceAll('\n', r'\n');

  void _log(LogKind kind, String text) {
    log.add(LogEntry(DateTime.now(), kind, text));
    if (log.length > maxLog) log.removeRange(0, log.length - maxLog);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  // ---- 接続 ----
  Future<void> startBle() async {
    await bridge.startBle(useFff0: useFff0);
    connState[TransportType.ble] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopBle() async {
    await bridge.stopBle();
    connState.remove(TransportType.ble);
    sessions.remove(TransportType.ble)?.dispose();
    notifyListeners();
  }

  Future<void> startSpp() async {
    await bridge.startSpp();
    connState[TransportType.spp] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopSpp() async {
    await bridge.stopSpp();
    connState.remove(TransportType.spp);
    sessions.remove(TransportType.spp)?.dispose();
    notifyListeners();
  }

  Future<void> startTcp() async {
    await tcp.start();
    connState[TransportType.tcp] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopTcp() async {
    await tcp.stop();
    connState.remove(TransportType.tcp);
    sessions.remove(TransportType.tcp)?.dispose();
    notifyListeners();
  }

  Future<void> disconnect(TransportType t) async {
    _log(LogKind.fault, '${t.label} を切断');
    try {
      if (t == TransportType.tcp) {
        await tcp.disconnect();
      } else {
        await bridge.disconnect(t);
      }
    } on MissingPluginException catch (e) {
      _logDisconnectFailure(t, e);
    } on PlatformException catch (e) {
      _logDisconnectFailure(t, e);
    }
  }

  void _logDisconnectFailure(TransportType t, Object e) =>
      _log(LogKind.info, '${t.label} の切断に失敗: $e');

  Future<void> disconnectAll() async {
    for (final t in connectedTransports) {
      await disconnect(t);
    }
  }

  void setBleProfile(bool fff0) {
    useFff0 = fff0;
    notifyListeners();
  }

  void setSimEnabled(bool on) {
    core.simulator.enabled = on;
    notifyListeners();
  }

  void notify() => notifyListeners();

  // ---- 障害 ----
  void updateFaults(void Function(FaultConfig f) change) {
    change(core.faultConfig);
    final active = activeFaultDescriptions();
    _log(
      LogKind.fault,
      active.isEmpty ? '障害: なし' : '障害: ${active.join(' / ')}',
    );
  }

  List<String> activeFaultDescriptions() {
    final f = core.faultConfig;
    final error = f.error;
    return [
      if (f.ignitionOff) 'イグニッション OFF',
      for (final p in core.ecus)
        if (f.silentEcus.contains(p.name)) '${p.label} の無応答',
      if (f.delayMs > 0) '応答の遅延 ${f.delayMs}ms',
      if (f.dropPercent > 0) 'ランダムな欠落 ${f.dropPercent}%',
      if (f.responsePending) '応答保留（7F xx 78）',
      if (f.truncateMultiFrame) '複数フレームの途中欠落',
      if (f.errorArmed && error != null)
        'エラー応答 ${error.text}（${f.errorTrigger == ErrorTrigger.once ? '次の1回' : '常に'}）',
    ];
  }

  // ---- DTC ----
  List<String> _list(EcuProfile e, DtcKind kind) => switch (kind) {
    DtcKind.confirmed => e.confirmedDtcs,
    DtcKind.pending => e.pendingDtcs,
    DtcKind.permanent => e.permanentDtcs,
  };

  /// 前後の空白を除き大文字にして追加する。形式違いは false。
  bool addDtc(EcuProfile e, DtcKind kind, String code) {
    final c = code.trim().toUpperCase();
    if (!isValidDtc(c)) return false;
    if (kind == DtcKind.confirmed) {
      core.obd.addConfirmedDtc(e, c);
    } else if (!_list(e, kind).contains(c)) {
      _list(e, kind).add(c);
    }
    notifyListeners();
    return true;
  }

  void removeDtc(EcuProfile e, DtcKind kind, String code) {
    _list(e, kind).remove(code);
    notifyListeners();
  }

  void clearDtcs(EcuProfile e) {
    core.obd.clearDtcs(e);
    notifyListeners();
  }

  // ---- ECU ----
  void setEcuEnabled(EcuProfile e, bool enabled) {
    e.enabled = enabled;
    notifyListeners();
  }

  static final _printable = RegExp(r'^[\x20-\x7E]*$');

  /// Mode 09 の情報を更新する。問題があればエラー文を返す（何も変えない）。
  String? updateEcuInfo(
    EcuProfile e, {
    required String vin,
    required String calid,
    required String cvnHex,
    required String name,
  }) {
    if (vin.isNotEmpty && (vin.length != 17 || !_printable.hasMatch(vin))) {
      return 'VIN は 17 文字（空にすると Mode 09 02 に応答しない）';
    }
    if (calid.isEmpty || calid.length > 16 || !_printable.hasMatch(calid)) {
      return 'CALID は 1〜16 文字';
    }
    final cvn = cvnHex.length == 8 ? parseHexBytes(cvnHex) : null;
    if (cvn == null) return 'CVN は 16 進 8 桁';
    if (name.isEmpty || name.length > 20 || !_printable.hasMatch(name)) {
      return 'ECU 名は 1〜20 文字';
    }
    e
      ..vin = vin
      ..calid = calid
      ..cvn = cvn
      ..ecuName = name;
    notifyListeners();
    return null;
  }

  void setDid(EcuProfile e, int did, DidValue value) {
    e.dids[did] = value;
    notifyListeners();
  }

  void removeDid(EcuProfile e, int did) {
    e.dids.remove(did);
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _unlistenBus?.call();
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in sessions.values) {
      s.dispose();
    }
    sessions.clear();
    unawaited(tcp.stop());
    core.dispose();
    super.dispose();
  }
}
