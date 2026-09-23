import 'package:test/test.dart';
import 'package:elm327emu/ecu/dtc.dart';

void main() {
  test('DTC 文字列 ⇔ 2 バイト', () {
    expect(dtcToBytes('P0301'), [0x03, 0x01]);
    expect(dtcToBytes('P0420'), [0x04, 0x20]);
    expect(dtcToBytes('U0100'), [0xC1, 0x00]);
    expect(dtcToBytes('C1234'), [0x52, 0x34]);
    expect(dtcFromBytes(0x03, 0x01), 'P0301');
    expect(dtcFromBytes(0xC1, 0x00), 'U0100');
  });

  test('isValidDtc', () {
    expect(isValidDtc('P0301'), isTrue);
    expect(isValidDtc('B3FFF'), isTrue);
    expect(isValidDtc('p0301'), isFalse);
    expect(isValidDtc('P4301'), isFalse);
    expect(isValidDtc('X0301'), isFalse);
    expect(isValidDtc('P030'), isFalse);
  });

  test('形式違いは dtcToBytes で例外', () {
    expect(() => dtcToBytes('X1'), throwsArgumentError);
  });
}
