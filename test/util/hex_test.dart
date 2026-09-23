import 'package:test/test.dart';
import 'package:elm327emu/util/hex.dart';

void main() {
  test('hex2 は 2 桁の大文字', () {
    expect(hex2(0), '00');
    expect(hex2(0x1A), '1A');
    expect(hex2(0x1FF), 'FF');
  });

  test('hexN は指定桁で 0 埋め', () {
    expect(hexN(0x7E8, 3), '7E8');
    expect(hexN(0x14, 3), '014');
    expect(hexN(0x18DAF110, 8), '18DAF110');
  });

  test('parseHexBytes', () {
    expect(parseHexBytes('010C'), [0x01, 0x0C]);
    expect(parseHexBytes('ff'), [0xFF]);
    expect(parseHexBytes(''), isNull);
    expect(parseHexBytes('010'), isNull);
    expect(parseHexBytes('0XYZ'), isNull);
  });
}
