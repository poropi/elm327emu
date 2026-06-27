import 'dart:async';
import 'package:flutter/foundation.dart';
import '../elm327/elm327_engine.dart';
import '../elm327/line_assembler.dart';
import '../transport/transport.dart';
import '../transport/transport_bridge.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';

class EmulatorController extends ChangeNotifier {
  final VehicleState vehicle = VehicleState.defaults();
  late final Elm327Engine engine = Elm327Engine(vehicle);
  late final Simulator simulator = Simulator(vehicle);
  final TransportBridge bridge = TransportBridge();

  final Map<TransportType, LineAssembler> _assemblers = {
    TransportType.ble: LineAssembler(),
    TransportType.spp: LineAssembler(),
  };

  List<TransportType> caps = [];
  final Map<TransportType, String> connState = {};
  final List<String> log = [];
  Timer? _simTimer;
  bool useFff0 = false;

  Future<void> init() async {
    caps = await bridge.capabilities();
    bridge.onReceive.listen(_onReceive);
    bridge.onConnection.listen((e) {
      connState[e.transport] = '${e.state} ${e.device}';
      _addLog('[${e.transport.wire}] ${e.state} ${e.device}');
    });
    notifyListeners();
  }

  void _onReceive(({TransportType transport, List<int> bytes}) e) {
    final lines = _assemblers[e.transport]!.addBytes(e.bytes);
    for (final line in lines) {
      _addLog('<= $line');
      final resp = engine.process(line);
      _addLog('=> ${resp.replaceAll('\r', '\\r')}');
      bridge.send(e.transport, resp.codeUnits);
    }
  }

  void setSimEnabled(bool on) {
    simulator.enabled = on;
    _simTimer?.cancel();
    if (on) {
      _simTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        simulator.tick(0.2);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> startBle() => bridge.startBle(useFff0: useFff0);
  Future<void> stopBle() => bridge.stopBle();
  Future<void> startSpp() => bridge.startSpp();
  Future<void> stopSpp() => bridge.stopSpp();

  void setBleProfile(bool fff0) {
    useFff0 = fff0;
    notifyListeners();
  }

  void _addLog(String s) {
    log.add(s);
    if (log.length > 500) log.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    super.dispose();
  }
}
