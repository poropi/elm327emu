import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/periodic_traffic.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import '../support/elm_harness.dart';

void t(String name, void Function(ElmHarness h, FakeAsync a) body) {
  test(name, () => fakeAsync((a) {
        final h = ElmHarness(a);
        PeriodicTraffic(h.bus, h.vehicle, h.faults).start();
        body(h, a);
      }));
}

void main() {
  t('ATMA（H0）は周期フレームを生の 8 バイトで流す', (h, a) {
    h.send('ATE0');
    final out = h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 25));
    expect(out, '0C 80 1F 00 00 00 00 00 \r');
    expect(h.session.mode, SessionMode.monitoring);
  });

  t('ATMA（H1）は ID 付き、何か受信すると STOPPED', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    final out = h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 25));
    expect(out, '0C9 0C 80 1F 00 00 00 00 00 \r');
    expect(h.sendRaw('X', elapse: const Duration(milliseconds: 1)), 'STOPPED\r\r>');
    expect(h.sendRaw('', elapse: const Duration(milliseconds: 100)), '');
  });

  t('ATMT E9 は下位 8bit が E9 のフレームだけ', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    final out = h.sendRaw('ATMTE9\r', elapse: const Duration(milliseconds: 105));
    expect(out, '3E9 00 00 00 00 00 00 00 00 \r');
  });

  t('ほかのセッションの診断通信と FC も見える', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    h.send('ATCRA7E0');
    h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 1));
    final other = h.newSession(sink: StringBuffer());
    other.input('ATE0\rATSH7E0\r0902\r'.codeUnits);
    final out = h.sendRaw('', elapse: const Duration(milliseconds: 100));
    expect(out, '7E0 02 09 02 00 00 00 00 00 \r7E0 FC: 30 00 00 00 00 00 00 00 \r');
  });

  t('29bit プロトコル中は 11bit の周期フレームを出さない', (h, a) {
    h.send('ATE0');
    h.send('ATSP7');
    expect(h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 100)), '');
  });

  t('ATRTR は RTR フレームを送り、監視側（H1）には RTR と出る', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    h.sendRaw('ATMTDF\r', elapse: const Duration(milliseconds: 1));
    final other = h.newSession(sink: StringBuffer());
    other.input('ATE0\rATRTR\r'.codeUnits);
    final out = h.sendRaw('', elapse: const Duration(milliseconds: 5));
    expect(out, contains('7DF RTR\r'));
  });
}
