import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/app/emulation_core.dart';

void main() {
  test('生成時にエンジンへ P0301 とフリーズフレーム', () {
    final core = EmulationCore();
    expect(core.engine.confirmedDtcs, ['P0301']);
    expect(core.engine.freezeFrame?.dtc, 'P0301');
    expect(core.ecus.map((e) => e.name), ['engine', 'transmission']);
    expect(core.ecuByName('transmission'), same(core.transmission));
  });

  test('start 後のセッションは ECU と周期フレームにつながる', () {
    fakeAsync((async) {
      final core = EmulationCore()..start();
      final s = core.newSession();
      final out = StringBuffer();
      s.output.listen((b) => out.write(String.fromCharCodes(b)));
      s.input('ATE0\r0100\r'.codeUnits);
      async.elapse(const Duration(milliseconds: 100));
      expect(out.toString(), 'ATE0\rOK\r\r>SEARCHING...\r41 00 BE 3F A0 13 \r\r>');
      final ids = <int>{};
      core.bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(milliseconds: 1000));
      expect(ids, containsAll([0x0C9, 0x3E9, 0x4C1]));
      core.dispose();
    });
  });
}
