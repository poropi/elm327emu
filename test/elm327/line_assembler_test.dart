import 'package:test/test.dart';
import 'package:elm327emu/elm327/line_assembler.dart';

List<int> b(String s) => s.codeUnits;

void main() {
  test('1 行を 1 コマンドとして返す', () {
    expect(LineAssembler().addBytes(b('010C\r')), ['010C']);
  });

  test('CR が来るまでは何も返さない', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010')), isEmpty);
    expect(a.addBytes(b('C\r')), ['010C']);
  });

  test('複数行を一度に分割する', () {
    expect(LineAssembler().addBytes(b('ATZ\r010C\r')), ['ATZ', '010C']);
  });

  test('LF・NUL・制御文字は捨て、空行は空文字として返す（旧: 捨てる）', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r\n')), ['ATZ']);
    expect(a.addBytes(b('\r')), ['']);
    expect(a.addBytes([0x00, 0x01, 0x41, 0x54, 0x49, 0x0D]), ['ATI']);
  });

  test('スペースと DEL は残す（エコーと ? 判定のため）', () {
    expect(LineAssembler().addBytes(b('AT RV\r')), ['AT RV']);
    expect(LineAssembler().addBytes([0x7F, 0x7F, 0x0D]), ['\x7F\x7F']);
  });
}
