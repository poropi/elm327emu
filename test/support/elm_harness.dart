import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/ecu/ecu.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/uds_services.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

/// 仮想バス・ECU 2 台・セッション 1 つの組み立て。fakeAsync の中で使う。
class ElmHarness {
  ElmHarness(this.async, {bool transmission = false, int seed = 1}) {
    transmissionProfile.enabled = transmission;
    faults = FaultInjector(faultConfig, random: Random(seed));
    obd = ObdServices(vehicle);
    obd.addConfirmedDtc(engineProfile, 'P0301');
    for (final p in [engineProfile, transmissionProfile]) {
      bus.attach(Ecu(profile: p, bus: bus, obd: obd, uds: UdsServices(), faults: faults));
    }
    session = newSession();
  }

  final FakeAsync async;
  final VirtualCanBus bus = VirtualCanBus();
  final VehicleState vehicle = VehicleState.defaults();
  final EcuProfile engineProfile = EcuProfile.engine();
  final EcuProfile transmissionProfile = EcuProfile.transmission();
  final FaultConfig faultConfig = FaultConfig();
  late final FaultInjector faults;
  late final ObdServices obd;
  late final ElmSession session;
  final StringBuffer _out = StringBuffer();
  int _read = 0;

  ElmSession newSession({StringBuffer? sink}) {
    final s = ElmSession(bus: bus, faults: faults, voltage: () => vehicle.batteryVoltage);
    s.output.listen((b) => (sink ?? _out).write(String.fromCharCodes(b)));
    return s;
  }

  String get all => _out.toString();

  /// [cmd] + CR を送り、'>' が出るまで（最大 20 秒ぶん）時間を進め、その間の出力を返す。
  String send(String cmd) => sendRaw('$cmd\r', untilPrompt: true);

  String sendRaw(String raw, {bool untilPrompt = false, Duration elapse = Duration.zero}) {
    final start = _read;
    session.input(raw.codeUnits);
    if (untilPrompt) {
      for (var i = 0; i < 20000 && !_out.toString().substring(start).endsWith('>'); i++) {
        async.elapse(const Duration(milliseconds: 1));
      }
    } else {
      async.elapse(elapse);
    }
    _read = _out.length;
    return _out.toString().substring(start, _read);
  }

  /// エコーを切り、0100 でプロトコルを確定させる（以後 SEARCHING... が出ない）。
  void quiet() {
    send('ATE0');
    send('0100');
  }
}
