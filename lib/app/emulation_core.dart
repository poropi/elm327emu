import 'dart:math';

import '../can/fault_injector.dart';
import '../can/periodic_traffic.dart';
import '../can/virtual_can_bus.dart';
import '../ecu/ecu.dart';
import '../ecu/ecu_profile.dart';
import '../ecu/obd_services.dart';
import '../ecu/uds_services.dart';
import '../elm327/elm_session.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';

/// 車両・ECU・バス・障害設定の組み立て。Flutter アプリと CLI の両方が使う。
class EmulationCore {
  EmulationCore({Random? random}) {
    faults = FaultInjector(faultConfig, random: random);
    obd = ObdServices(vehicle);
    obd.addConfirmedDtc(engine, 'P0301');
    simulator = Simulator(vehicle, milOn: () => engine.confirmedDtcs.isNotEmpty);
    traffic = PeriodicTraffic(bus, vehicle, faults);
  }

  final VehicleState vehicle = VehicleState.defaults();
  final EcuProfile engine = EcuProfile.engine();
  final EcuProfile transmission = EcuProfile.transmission();
  late final List<EcuProfile> ecus = [engine, transmission];
  final VirtualCanBus bus = VirtualCanBus();
  final FaultConfig faultConfig = FaultConfig();
  late final FaultInjector faults;
  late final ObdServices obd;
  final UdsServices uds = UdsServices();
  late final Simulator simulator;
  late final PeriodicTraffic traffic;

  final List<Ecu> _nodes = [];

  EcuProfile ecuByName(String name) => ecus.firstWhere((e) => e.name == name);

  void start() {
    if (_nodes.isNotEmpty) return;
    for (final p in ecus) {
      final node = Ecu(profile: p, bus: bus, obd: obd, uds: uds, faults: faults);
      bus.attach(node);
      _nodes.add(node);
    }
    traffic.start();
  }

  ElmSession newSession() =>
      ElmSession(bus: bus, faults: faults, voltage: () => vehicle.batteryVoltage);

  void dispose() {
    traffic.stop();
    for (final n in _nodes) {
      n.dispose();
    }
    _nodes.clear();
  }
}
