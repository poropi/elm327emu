import 'package:test/test.dart';
import 'package:elm327emu/elm327/line_assembler.dart';

List<int> b(String s) => s.codeUnits;

void main() {
  test('1行を1コマンドとして返す', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010C\r')), ['010C']);
  });

  test('CRが来るまでは何も返さない', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010')), isEmpty);
    expect(a.addBytes(b('C\r')), ['010C']);
  });

  test('複数行を一度に分割', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r010C\r')), ['ATZ', '010C']);
  });

  test('LFは無視し空行は捨てる', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r\n')), ['ATZ']);
    expect(a.addBytes(b('\r')), isEmpty);
  });
}
