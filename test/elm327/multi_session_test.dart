import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import '../support/elm_harness.dart';

/// 1 本のバスを共有する複数セッション（BLE・SPP・TCP の同時接続）の分離（最終レビュー I3）。
class _Client {
  _Client(ElmHarness h) {
    session = h.newSession(sink: out);
  }
  final StringBuffer out = StringBuffer();
  late final ElmSession session;

  void input(String s) => session.input(s.codeUnits);
  String take() {
    final s = out.toString();
    out.clear();
    return s;
  }
}

void t(String name, void Function(ElmHarness h, FakeAsync async) body) {
  test(name, () => fakeAsync((async) => body(ElmHarness(async), async)));
}

const _vinH0 =
    '014\r0: 49 02 01 57 41 55 \r1: 5A 5A 5A 38 4B 39 41 \r2: 41 30 30 30 30 30 30 \r\r>';
const _calidH0 =
    '013\r0: 49 04 01 38 4B 30 \r1: 39 30 37 31 31 35 42 \r2: 20 20 30 30 31 30 \r\r>';

void main() {
  List<_Client> clients(ElmHarness h, FakeAsync a, String setup) {
    final list = [_Client(h), _Client(h)];
    for (final c in list) {
      c.input(setup);
    }
    a.elapse(const Duration(milliseconds: 5));
    for (final c in list) {
      c.take();
    }
    return list;
  }

  t('同時に 010C と 010D を送ると、各セッションには自分の 1 行だけ', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATH1\rATSP6\r');
    x.input('010C\r');
    y.input('010D\r');
    a.elapse(const Duration(milliseconds: 400));
    expect(x.take(), '7E8 04 41 0C 0C 80 00 00 00 \r\r>');
    expect(y.take(), '7E8 03 41 0D 00 00 00 00 00 \r\r>');
  });

  t('同時に 0902 と 0904（H1）: VIN と CALID がそれぞれに 3 フレームずつ', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATH1\rATSP6\r');
    x.input('0902\r');
    y.input('0904\r');
    a.elapse(const Duration(milliseconds: 600));
    expect(
      x.take(),
      '7E8 10 14 49 02 01 57 41 55 \r7E8 21 5A 5A 5A 38 4B 39 41 \r7E8 22 41 30 30 30 30 30 30 \r\r>',
    );
    expect(
      y.take(),
      '7E8 10 13 49 04 01 38 4B 30 \r7E8 21 39 30 37 31 31 35 42 \r7E8 22 20 20 30 30 31 30 00 \r\r>',
    );
  });

  t('同時に 0902 と 0904（H0、9ms ずらし）: どちらも正しく組み立つ', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATSP6\r');
    x.input('0902\r');
    a.elapse(const Duration(milliseconds: 9));
    y.input('0904\r');
    a.elapse(const Duration(milliseconds: 600));
    expect(x.take(), _vinH0);
    expect(y.take(), _calidH0);
  });

  t('3 つ目のセッションが ATMA 中なら、両方の要求・応答・FC が見える', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATSP6\r');
    final m = _Client(h);
    m.input('ATE0\rATSP6\rATH1\rATMA\r');
    a.elapse(const Duration(milliseconds: 5));
    m.take();
    x.input('0902\r');
    y.input('0904\r');
    a.elapse(const Duration(milliseconds: 600));
    final lines = m.take().split('\r').where((l) => l.isNotEmpty).toList();
    expect(lines, contains('7DF 02 09 02 00 00 00 00 00 '));
    expect(lines, contains('7DF 02 09 04 00 00 00 00 00 '));
    expect(lines.where((l) => l.startsWith('7E0 FC: 30 ')).length, 2);
    expect(lines.where((l) => l.startsWith('7E8 ')).length, 6);
    expect(lines, contains('7E8 10 14 49 02 01 57 41 55 '));
    expect(lines, contains('7E8 10 13 49 04 01 38 4B 30 '));
    expect(x.take(), _vinH0);
    expect(y.take(), _calidH0);
  });

  t('片方が FC を送らない（CFC0）と、もう片方の複数フレームだけが続く', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATSP6\r');
    x.input('ATCFC0\r');
    a.elapse(const Duration(milliseconds: 1));
    x.take();
    x.input('0902\r');
    y.input('0904\r');
    a.elapse(const Duration(milliseconds: 600));
    expect(x.take(), '014\r0: 49 02 01 57 41 55 \r\r>');
    expect(y.take(), _calidH0);
  });

  t('片方のセッションを要求中に閉じても、もう片方は影響を受けない', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATSP6\r');
    x.input('0902\r');
    y.input('0904\r');
    x.session.dispose();
    a.elapse(const Duration(milliseconds: 600));
    expect(y.take(), _calidH0);
    expect(y.session.mode, SessionMode.idle);
  });

  t('全 ID を通すフィルタ（CF000 + CM000）でも、他セッションの要求・FC・応答は拾わない', (h, a) {
    final [x, y] = clients(h, a, 'ATE0\rATH1\rATSP6\rATCF000\rATCM000\r');
    x.input('0902\r');
    y.input('010D\r');
    a.elapse(const Duration(milliseconds: 600));
    expect(
      x.take(),
      '7E8 10 14 49 02 01 57 41 55 \r7E8 21 5A 5A 5A 38 4B 39 41 \r7E8 22 41 30 30 30 30 30 30 \r\r>',
    );
    expect(y.take(), '7E8 03 41 0D 00 00 00 00 00 \r\r>');
  });
}
