import 'package:test/test.dart';
import 'package:elm327emu/vehicle/simulator.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void ticks(Simulator s, double seconds) {
  for (var i = 0; i < (seconds / 0.2).round(); i++) {
    s.tick(0.2);
  }
}

void main() {
  test('disabled なら走行値は変化しない', () {
    final v = VehicleState.defaults();
    final s = Simulator(v);
    final rpm0 = v.rpm;
    s.tick(1.0);
    expect(v.rpm, rpm0);
  });

  test('enabled で加速フェーズは RPM/速度が上がる', () {
    final v = VehicleState.defaults()
      ..speedKmh = 0
      ..rpm = 800;
    final s = Simulator(v)..enabled = true;
    ticks(s, 6);
    expect(v.speedKmh, greaterThan(0));
    expect(v.rpm, greaterThan(800));
  });

  test('値は妥当な範囲に収まる', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    ticks(s, 400);
    expect(v.speedKmh, inInclusiveRange(0, 200));
    expect(v.rpm, inInclusiveRange(600, 7000));
    expect(v.engineLoadPct, inInclusiveRange(0, 100));
    expect(v.mapKpa, inInclusiveRange(20, 101));
    expect(v.timingDeg, inInclusiveRange(-10, 40));
    expect(v.fuelRateLph, greaterThanOrEqualTo(0));
  });

  test('積算: 36 km/h で 100 秒 → 1 km、経過時間 100 秒（disabled でも進む）', () {
    final v = VehicleState.defaults()..speedKmh = 36;
    final s = Simulator(v);
    final odo0 = v.odometerKm;
    ticks(s, 100);
    expect(v.odometerKm - odo0, closeTo(1.0, 1e-6));
    expect(v.distanceSinceClearKm, closeTo(1.0, 1e-6));
    expect(v.runTimeSec, closeTo(100, 1e-6));
    expect(v.secondsSinceClear, closeTo(100, 1e-6));
    expect(v.distanceWithMilKm, 0);
  });

  test('MIL 点灯中は MIL 距離・時間も進む', () {
    final v = VehicleState.defaults()..speedKmh = 36;
    final s = Simulator(v, milOn: () => true);
    ticks(s, 100);
    expect(v.distanceWithMilKm, closeTo(1.0, 1e-6));
    expect(v.secondsWithMil, closeTo(100, 1e-6));
  });

  test('レディネスは 60 秒ごとに 1 項目ずつ完了', () {
    final v = VehicleState.defaults()..readinessIncomplete = 0x65;
    final s = Simulator(v);
    ticks(s, 59.8);
    expect(v.readinessIncomplete, 0x65);
    ticks(s, 0.2);
    expect(v.readinessIncomplete, 0x64);
    ticks(s, 180);
    expect(v.readinessIncomplete, 0x00);
  });

  test('水温が 60°C 未満から 70°C 以上になるとウォームアップ 1 回', () {
    final v = VehicleState.defaults()..coolantTempC = 30;
    final s = Simulator(v);
    s.tick(0.2);
    v.coolantTempC = 75;
    s.tick(0.2);
    v.coolantTempC = 80;
    s.tick(0.2);
    expect(v.warmupsSinceClear, 1);
  });

  test('派生値: 動的モード中は MAF から燃料消費率を計算', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    s.tick(0.2);
    expect(v.fuelRateLph, closeTo(v.maf / 14.7 / 745 * 3600, 1e-9));
    expect(v.acceleratorPct, closeTo(v.throttlePct * 0.8, 1e-9));
  });
}
