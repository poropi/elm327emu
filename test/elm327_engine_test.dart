import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm327_engine.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late Elm327Engine e;
  setUp(() => e = Elm327Engine(VehicleState.defaults()));

  test('ATZ: echo + 識別子 + プロンプト', () {
    final r = e.process('ATZ');
    expect(r, 'ATZ\rELM327 v1.5\r\r>');
  });

  test('echo OFF 後はエコーしない', () {
    e.process('ATE0');
    final r = e.process('ATI');
    expect(r, 'ELM327 v1.5\r\r>');
  });

  test('OBD 応答にプロンプト', () {
    e.process('ATE0');
    e.state.initialized = true;
    e.vehicle.rpm = 1726;
    final r = e.process('010C');
    expect(r, '41 0C 1A F8 \r\r>');
  });

  test('linefeed ON は CRLF', () {
    e.process('ATE0');
    e.process('ATL1');
    final r = e.process('ATI');
    expect(r, 'ELM327 v1.5\r\n\r\n>');
  });
}
