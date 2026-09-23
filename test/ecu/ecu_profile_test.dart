import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';

void main() {
  test('エンジンの ID と既定値', () {
    final e = EcuProfile.engine();
    expect(e.name, 'engine');
    expect(e.enabled, isTrue);
    expect(e.requestId11, 0x7E0);
    expect(e.responseId11, 0x7E8);
    expect(e.requestId29, 0x18DA10F1);
    expect(e.responseId29For(0xF1), 0x18DAF110);
    expect(e.baseLatency, const Duration(milliseconds: 8));
    expect(e.mode01Pids.length, 38);
    expect(e.mode09Pids, {0x02, 0x04, 0x06, 0x0A});
    expect(e.confirmedDtcs, isEmpty);
    expect(e.calid.length, 16);
    expect(e.dids.keys, containsAll([0xF190, 0xF187, 0xF18C, 0xF191]));
  });

  test('トランスミッションは無効・PID は 01 と A4 のみ・VIN なし', () {
    final t = EcuProfile.transmission();
    expect(t.enabled, isFalse);
    expect(t.requestId11, 0x7E1);
    expect(t.responseId11, 0x7E9);
    expect(t.requestId29, 0x18DA18F1);
    expect(t.responseId29For(0xF1), 0x18DAF118);
    expect(t.baseLatency, const Duration(milliseconds: 15));
    expect(t.mode01Pids, {0x01, 0xA4});
    expect(t.mode09Pids, {0x04, 0x06, 0x0A});
  });

  test('DidValue', () {
    expect(DidValue.ascii('AB').bytes, [0x41, 0x42]);
    expect(DidValue.ascii('AB').display, 'AB');
    expect(DidValue.hex([0x0A, 0x1B]).display, '0A 1B');
    expect(() => DidValue.ascii('A\u0001'), throwsArgumentError);
    expect(() => DidValue.hex([]), throwsArgumentError);
  });

  test('エンジンの VIN を空にすると Mode 09 の 02 が消える', () {
    final e = EcuProfile.engine()..vin = '';
    expect(e.mode09Pids, {0x04, 0x06, 0x0A});
  });
}
