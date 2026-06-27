import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';
import 'package:elm327emu/vehicle/simulator.dart';

void main() {
  test('disabled なら変化しない', () {
    final v = VehicleState.defaults();
    final s = Simulator(v);
    final rpm0 = v.rpm;
    s.tick(1.0);
    expect(v.rpm, rpm0);
  });

  test('enabled で加速フェーズはRPM/速度が上がる', () {
    final v = VehicleState.defaults()..speedKmh = 0..rpm = 800;
    final s = Simulator(v)..enabled = true;
    for (var i = 0; i < 30; i++) {
      s.tick(0.2);
    }
    expect(v.speedKmh, greaterThan(0));
    expect(v.rpm, greaterThan(800));
  });

  test('値は妥当な範囲に収まる', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    for (var i = 0; i < 2000; i++) {
      s.tick(0.2);
    }
    expect(v.speedKmh, inInclusiveRange(0, 200));
    expect(v.rpm, inInclusiveRange(600, 7000));
    expect(v.engineLoadPct, inInclusiveRange(0, 100));
  });
}
