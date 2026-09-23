import 'package:test/test.dart';
import 'package:elm327emu/can/iso_tp.dart';

final _vin = [0x49, 0x02, 0x01, ...'WAUZZZ8K9AA000000'.codeUnits];

void main() {
  group('segment', () {
    test('7 バイト以下は SF 1 つ（0x00 で 8 バイトに詰める）', () {
      expect(segment([0x41, 0x0C, 0x0C, 0x80]), [
        [0x04, 0x41, 0x0C, 0x0C, 0x80, 0x00, 0x00, 0x00],
      ]);
    });

    test('pad: false なら詰めない', () {
      expect(segment([0x44], pad: false), [
        [0x01, 0x44],
      ]);
    });

    test('VIN（20 バイト）は FF と CF 2 つ', () {
      expect(segment(_vin), [
        [0x10, 0x14, 0x49, 0x02, 0x01, 0x57, 0x41, 0x55],
        [0x21, 0x5A, 0x5A, 0x5A, 0x38, 0x4B, 0x39, 0x41],
        [0x22, 0x41, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30],
      ]);
    });

    test('連番は F の次に 0 へ戻る', () {
      final frames = segment(List.generate(6 + 7 * 16, (i) => i & 0xFF));
      expect(frames[15][0], 0x2F);
      expect(frames[16][0], 0x20);
    });

    test('空と 4096 バイト以上は拒否', () {
      expect(() => segment([]), throwsArgumentError);
      expect(() => segment(List.filled(4096, 0)), throwsArgumentError);
    });
  });

  test('frameType', () {
    expect(
      frameType([0x04, 0x41, 0x0C, 0x0C, 0x80, 0, 0, 0]),
      FrameType.single,
    );
    expect(frameType([0x00, 0, 0]), FrameType.invalid);
    expect(frameType([0x08, 0, 0, 0, 0, 0, 0, 0]), FrameType.invalid);
    expect(frameType([0x03, 0x41]), FrameType.invalid); // 長さが足りない
    expect(frameType([0x10, 0x14, 0, 0, 0, 0, 0, 0]), FrameType.first);
    expect(frameType([0x21, 0, 0]), FrameType.consecutive);
    expect(frameType([0x30, 0, 0]), FrameType.flowControl);
    expect(frameType([0x40]), FrameType.invalid);
    expect(frameType([]), FrameType.invalid);
  });

  test('flowControl', () {
    expect(flowControl(), [0x30, 0, 0, 0, 0, 0, 0, 0]);
    expect(flowControl(blockSize: 2, stMin: 5).sublist(0, 3), [0x30, 2, 5]);
  });

  group('Reassembler', () {
    test('SF はパディングを除いて返す', () {
      expect(Reassembler().add([0x04, 0x41, 0x0C, 0x0C, 0x80, 0, 0, 0]), [
        0x41,
        0x0C,
        0x0C,
        0x80,
      ]);
    });

    test('FF と CF から復元する', () {
      final r = Reassembler();
      final frames = segment(_vin);
      expect(r.add(frames[0]), isNull);
      expect(r.inProgress, isTrue);
      expect(r.add(frames[1]), isNull);
      expect(r.add(frames[2]), _vin);
      expect(r.inProgress, isFalse);
    });

    test('連番が飛んだら破棄する', () {
      final r = Reassembler();
      final frames = segment(_vin);
      r.add(frames[0]);
      expect(r.add(frames[2]), isNull);
      expect(r.inProgress, isFalse);
    });

    test('FF なしの CF は無視する', () {
      expect(Reassembler().add([0x21, 1, 2, 3, 4, 5, 6, 7]), isNull);
    });

    test('長さ 1〜300 の全長で segment → add が元に戻る', () {
      for (var n = 1; n <= 300; n++) {
        final payload = List.generate(n, (i) => (i * 7) & 0xFF);
        final r = Reassembler();
        List<int>? out;
        for (final f in segment(payload)) {
          out = r.add(f);
        }
        expect(out, payload, reason: 'length $n');
      }
    });
    test('宣言長 7 以下の FF は不正扱い、続く CF で例外にならない', () {
      expect(frameType([0x10, 0x04, 1, 2, 3, 4, 5, 6]), FrameType.invalid);
      expect(frameType([0x10, 0x07, 1, 2, 3, 4, 5, 6]), FrameType.invalid);
      expect(frameType([0x10, 0x08, 1, 2, 3, 4, 5, 6]), FrameType.first);
      final r = Reassembler();
      expect(r.add([0x10, 0x04, 1, 2, 3, 4, 5, 6]), isNull);
      expect(r.inProgress, isFalse);
      expect(r.add([0x21, 9, 9, 9, 9, 9, 9, 9]), isNull);
    });
  });
}
