import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';
import 'package:elm327emu/elm327/obd_encoding.dart';

void main() {
  test('既定値', () {
    final v = VehicleState.defaults();
    expect(v.rpm, 800);
    expect(v.speedKmh, 0);
    expect(v.vin.length, 17);
    expect(v.dtcs, ['P0301']);
    expect(v.batteryVoltage, 12.4);
  });

  test('toHex2', () {
    expect(toHex2(0), '00');
    expect(toHex2(255), 'FF');
    expect(toHex2(26), '1A');
  });

  test('RPM分解 1726rpm -> 1A F8', () {
    expect(rpmA(1726), 0x1A);
    expect(rpmB(1726), 0xF8);
  });

  test('DTC文字列⇔バイト', () {
    expect(dtcToBytes('P0301'), [0x03, 0x01]);
    expect(dtcFromBytes(0x03, 0x01), 'P0301');
    expect(dtcToBytes('U0100'), [0xC1, 0x00]);
  });

  test('formatBytes spaces有無', () {
    expect(formatBytes([0x41, 0x0C, 0x1A, 0xF8], spaces: true), '41 0C 1A F8 ');
    expect(formatBytes([0x41, 0x0C, 0x1A, 0xF8], spaces: false), '410C1AF8');
  });

  test('ISO-TP 短データは1行', () {
    expect(isoTpMultiline([0x41, 0x0C, 0x1A, 0xF8]), ['41 0C 1A F8 ']);
  });

  test('ISO-TP 長データは総数+N行', () {
    final data = List<int>.generate(20, (i) => i + 1);
    final lines = isoTpMultiline(data);
    expect(lines.first, '014'); // 20 = 0x14
    expect(lines[1].startsWith('0:'), isTrue);
    expect(lines.length, greaterThan(2));
  });
}
