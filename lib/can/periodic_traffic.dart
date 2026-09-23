import 'dart:async';

import '../ecu/pid_table.dart';
import '../vehicle/vehicle_state.dart';
import 'can_frame.dart';
import 'fault_injector.dart';
import 'virtual_can_bus.dart';

/// ATMA で見える周期フレーム。実在車種の形式ではなく、このエミュレータ独自の形式。
class PeriodicTraffic {
  PeriodicTraffic(this.bus, this.vehicle, this.faults);

  final VirtualCanBus bus;
  final VehicleState vehicle;
  final FaultInjector faults;

  static const Set<int> ids = {0x0C9, 0x3E9, 0x4C1};

  final List<Timer> _timers = [];

  void start() {
    stop();
    _timers
      ..add(Timer.periodic(const Duration(milliseconds: 20), (_) => _send(0x0C9, _engine)))
      ..add(Timer.periodic(const Duration(milliseconds: 100), (_) => _send(0x3E9, _speed)))
      ..add(Timer.periodic(const Duration(milliseconds: 1000), (_) => _send(0x4C1, _temps)));
  }

  void stop() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void _send(int id, List<int> Function() build) {
    if (faults.config.ignitionOff) return;
    bus.transmit(CanFrame(id, build()), sender: this);
  }

  List<int> _engine() {
    final r = (vehicle.rpm * 4).clamp(0, 0xFFFF).toInt();
    return [r >> 8, r & 0xFF, pct255(vehicle.throttlePct), 0, 0, 0, 0, 0];
  }

  List<int> _speed() {
    final s = (vehicle.speedKmh * 100).round().clamp(0, 0xFFFF).toInt();
    return [s >> 8, s & 0xFF, 0, 0, 0, 0, 0, 0];
  }

  List<int> _temps() =>
      [temp40(vehicle.coolantTempC), temp40(vehicle.oilTempC), 0, 0, 0, 0, 0, 0];
}
