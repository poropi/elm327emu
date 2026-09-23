import 'vehicle_state.dart';

enum _Phase { idle, accel, cruise, decel }

/// 車両状態を時間で動かす。tick(dt) を外部から駆動する。
/// 積算（距離・時間・レディネス）は常に、走行パターンと派生値は enabled のときだけ進める。
class Simulator {
  Simulator(this.vehicle, {bool Function()? milOn}) : _milOn = milOn ?? (() => false);

  final VehicleState vehicle;
  final bool Function() _milOn;
  bool enabled = false;

  static const readinessStepSec = 60.0;

  _Phase _phase = _Phase.idle;
  double _phaseT = 0;
  double _readinessT = 0;
  bool _coldSeen = false;

  static const _phaseDur = {
    _Phase.idle: 3.0,
    _Phase.accel: 8.0,
    _Phase.cruise: 10.0,
    _Phase.decel: 6.0,
  };

  void tick(double dtSec) {
    _accumulate(dtSec);
    if (!enabled) return;
    _phaseT += dtSec;
    if (_phaseT >= _phaseDur[_phase]!) {
      _phaseT = 0;
      _phase = _next(_phase);
    }
    switch (_phase) {
      case _Phase.idle:
        _approach(targetSpeed: 0, targetRpm: 800, dt: dtSec);
      case _Phase.accel:
        _approach(targetSpeed: 100, targetRpm: 3500, dt: dtSec);
      case _Phase.cruise:
        _approach(targetSpeed: 90, targetRpm: 2200, dt: dtSec);
      case _Phase.decel:
        _approach(targetSpeed: 0, targetRpm: 900, dt: dtSec);
    }
    _deriveSecondary();
  }

  void _accumulate(double dt) {
    final v = vehicle;
    final km = v.speedKmh * dt / 3600;
    v
      ..runTimeSec += dt
      ..odometerKm += km
      ..distanceSinceClearKm += km
      ..secondsSinceClear += dt;
    if (_milOn()) {
      v
        ..distanceWithMilKm += km
        ..secondsWithMil += dt;
    }
    if (v.coolantTempC < 60) {
      _coldSeen = true;
    } else if (_coldSeen && v.coolantTempC >= 70) {
      v.warmupsSinceClear++;
      _coldSeen = false;
    }
    if (v.readinessIncomplete == 0) {
      _readinessT = 0;
      return;
    }
    _readinessT += dt;
    if (_readinessT >= readinessStepSec - 1e-9) {
      _readinessT = 0;
      v.readinessIncomplete &= v.readinessIncomplete - 1; // 最下位の未完了ビットを完了にする
    }
  }

  _Phase _next(_Phase p) => switch (p) {
        _Phase.idle => _Phase.accel,
        _Phase.accel => _Phase.cruise,
        _Phase.cruise => _Phase.decel,
        _Phase.decel => _Phase.idle,
      };

  void _approach({required double targetSpeed, required int targetRpm, required double dt}) {
    final k = (dt * 0.6).clamp(0.0, 1.0);
    vehicle.speedKmh += (targetSpeed - vehicle.speedKmh) * k;
    vehicle.rpm += ((targetRpm - vehicle.rpm) * k).round();
    vehicle.speedKmh = vehicle.speedKmh.clamp(0, 200);
    vehicle.rpm = vehicle.rpm.clamp(600, 7000);
  }

  void _deriveSecondary() {
    final v = vehicle;
    v.throttlePct = ((v.rpm - 800) / 6200 * 100).clamp(0, 100);
    v.engineLoadPct = (v.throttlePct * 0.8 + 15).clamp(0, 100);
    v.maf = (v.rpm / 800 * 3.5).clamp(0, 200);
    v.coolantTempC = (v.coolantTempC + (90 - v.coolantTempC) * 0.01).clamp(20, 110);
    v.mapKpa = (25 + v.throttlePct * 0.7).clamp(20, 101);
    v.timingDeg = (10 + (v.rpm - 800) / 6200 * 25).clamp(-10, 40);
    v.fuelRateLph = v.maf / 14.7 / 745 * 3600; // 空燃比 14.7、ガソリン 745 g/L
    v.catalystTempC += (400 + v.engineLoadPct * 3 - v.catalystTempC) * 0.02;
    v.oilTempC += (v.coolantTempC + 5 - v.oilTempC) * 0.01;
    v.acceleratorPct = v.throttlePct * 0.8;
    v.absLoadPct = v.engineLoadPct * 0.9;
  }
}
