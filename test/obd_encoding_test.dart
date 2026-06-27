import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  test('既定値', () {
    final v = VehicleState.defaults();
    expect(v.rpm, 800);
    expect(v.speedKmh, 0);
    expect(v.vin.length, 17);
    expect(v.dtcs, ['P0301']);
    expect(v.batteryVoltage, 12.4);
  });
}
