import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/uds_services.dart';

void main() {
  final uds = UdsServices();
  final engine = EcuProfile.engine();

  test('22 F190 は 62 F1 90 + VIN', () {
    expect(uds.handle([0x22, 0xF1, 0x90], engine, functional: false), [
      0x62,
      0xF1,
      0x90,
      ...'WAUZZZ8K9AA000000'.codeUnits,
    ]);
  });
  test('22 F191 は HEX の値', () {
    expect(uds.handle([0x22, 0xF1, 0x91], engine, functional: false), [
      0x62,
      0xF1,
      0x91,
      0x0A,
      0x1B,
      0x2C,
      0x3D,
    ]);
  });
  test('表にない DID は 7F 22 31、長さ違いは 7F 22 13', () {
    expect(uds.handle([0x22, 0x12, 0x34], engine, functional: false), [
      0x7F,
      0x22,
      0x31,
    ]);
    expect(uds.handle([0x22, 0xF1], engine, functional: false), [
      0x7F,
      0x22,
      0x13,
    ]);
    expect(
      uds.handle([0x22, 0xF1, 0x90, 0xF1, 0x87], engine, functional: false),
      [0x7F, 0x22, 0x13],
    );
  });
  test('未対応サービスは ECU 指定なら 7F SID 11、全 ECU 宛てなら無応答', () {
    expect(uds.handle([0x10, 0x03], engine, functional: false), [
      0x7F,
      0x10,
      0x11,
    ]);
    expect(uds.handle([0x27, 0x01], engine, functional: false), [
      0x7F,
      0x27,
      0x11,
    ]);
    expect(uds.handle([0x10, 0x03], engine, functional: true), isNull);
  });
  test('全 ECU 宛ての 22 は無応答', () {
    expect(uds.handle([0x22, 0xF1, 0x90], engine, functional: true), isNull);
  });
}
