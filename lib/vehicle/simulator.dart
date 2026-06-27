import 'vehicle_state.dart';

enum _Phase { idle, accel, cruise, decel }

/// 動的に車両状態を更新するシミュレータ。tick(dt) を外部から駆動する。
class Simulator {
  Simulator(this.vehicle);
  final VehicleState vehicle;
  bool enabled = false;

  _Phase _phase = _Phase.idle;
  double _phaseT = 0;

  static const _phaseDur = {
    _Phase.idle: 3.0,
    _Phase.accel: 8.0,
    _Phase.cruise: 10.0,
    _Phase.decel: 6.0,
  };

  void tick(double dtSec) {
    if (!enabled) return;
    _phaseT += dtSec;
    if (_phaseT >= _phaseDur[_phase]!) {
      _phaseT = 0;
      _phase = _next(_phase);
    }
    switch (_phase) {
      case _Phase.idle:
        _approach(targetSpeed: 0, targetRpm: 800, dt: dtSec);
        break;
      case _Phase.accel:
        _approach(targetSpeed: 100, targetRpm: 3500, dt: dtSec);
        break;
      case _Phase.cruise:
        _approach(targetSpeed: 90, targetRpm: 2200, dt: dtSec);
        break;
      case _Phase.decel:
        _approach(targetSpeed: 0, targetRpm: 900, dt: dtSec);
        break;
    }
    _deriveSecondary();
  }

  _Phase _next(_Phase p) {
    switch (p) {
      case _Phase.idle:
        return _Phase.accel;
      case _Phase.accel:
        return _Phase.cruise;
      case _Phase.cruise:
        return _Phase.decel;
      case _Phase.decel:
        return _Phase.idle;
    }
  }

  void _approach(
      {required double targetSpeed, required int targetRpm, required double dt}) {
    final k = (dt * 0.6).clamp(0.0, 1.0);
    vehicle.speedKmh += (targetSpeed - vehicle.speedKmh) * k;
    vehicle.rpm += ((targetRpm - vehicle.rpm) * k).round();
    vehicle.speedKmh = vehicle.speedKmh.clamp(0, 200);
    vehicle.rpm = vehicle.rpm.clamp(600, 7000);
  }

  void _deriveSecondary() {
    vehicle.throttlePct = ((vehicle.rpm - 800) / 6200 * 100).clamp(0, 100);
    vehicle.engineLoadPct = (vehicle.throttlePct * 0.8 + 15).clamp(0, 100);
    vehicle.maf = (vehicle.rpm / 800 * 3.5).clamp(0, 200);
    vehicle.coolantTempC =
        (vehicle.coolantTempC + (90 - vehicle.coolantTempC) * 0.01).clamp(20, 110);
  }
}
