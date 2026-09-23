import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/iso_tp.dart';
import 'package:elm327emu/can/periodic_traffic.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import '../support/elm_harness.dart';

void t(
  String name,
  void Function(ElmHarness h, FakeAsync async) body, {
  bool transmission = false,
}) {
  test(
    name,
    () => fakeAsync(
      (async) => body(ElmHarness(async, transmission: transmission), async),
    ),
  );
}

Duration timed(FakeAsync async, void Function() fn) {
  final start = async.elapsed;
  fn();
  return async.elapsed - start;
}

void main() {
  group('出力の形', () {
    t('ATZ はエコー + 空行 2 つ + ID', (h, a) {
      expect(h.send('ATZ'), 'ATZ\r\r\rELM327 v1.5\r\r>');
    });
    t('ATE0 の応答まではエコーする', (h, a) {
      expect(h.send('ATE0'), 'ATE0\rOK\r\r>');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
    t('L1 は CRLF', (h, a) {
      h.send('ATE0');
      h.send('ATL1');
      expect(h.send('ATI'), 'ELM327 v1.5\r\n\r\n>');
    });
    t('小文字とスペースも受け付ける', (h, a) {
      h.send('ATE0');
      expect(h.send('at i'), 'ELM327 v1.5\r\r>');
      expect(h.send('01 0c'), 'SEARCHING...\r41 0C 0C 80 \r\r>');
    });
  });

  group('プロトコル確定', () {
    t('最初の OBD 要求だけ SEARCHING...、確定後の DPN は A6', (h, a) {
      h.send('ATE0');
      expect(h.send('0100'), 'SEARCHING...\r41 00 BE 3F A0 13 \r\r>');
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r\r>');
      expect(h.send('ATDPN'), 'A6\r\r>');
      expect(h.send('ATDP'), 'AUTO, ISO 15765-4 (CAN 11/500)\r\r>');
    });
    t('ATSP6（固定）では SEARCHING... を出さない', (h, a) {
      h.send('ATE0');
      h.send('ATSP6');
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
      expect(h.send('ATDPN'), '6\r\r>');
    });
    t('検索中に応答がなければ UNABLE TO CONNECT（旧: NO DATA）', (h, a) {
      h.send('ATE0');
      expect(h.send('01FF'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
      expect(h.send('ATDPN'), 'A0\r\r>');
    });
    t('CAN 以外を固定すると 3〜5 は BUS INIT: ...ERROR、1 は NO DATA', (h, a) {
      h.send('ATE0');
      h.send('ATSP3');
      expect(h.send('0100'), 'BUS INIT: ...ERROR\r\r>');
      h.send('ATSP1');
      expect(h.send('0100'), 'NO DATA\r\r>');
    });
    t('ATSP7 は 29bit、ヘッダ表示は 4 バイト', (h, a) {
      h.send('ATE0');
      h.send('ATSP7');
      h.send('ATH1');
      expect(h.send('010C'), '18 DA F1 10 04 41 0C 0C 80 00 00 00 \r\r>');
    });
    t('29bit の複数フレーム応答では FC をエンジン（18DA10F1）へ送る', (h, a) {
      h.send('ATE0');
      h.send('ATSP7');
      final fcIds = <int>[];
      final cancel = h.bus.listen((e) {
        if (frameType(e.frame.data) == FrameType.flowControl) {
          fcIds.add(e.frame.id);
        }
      });
      h.send('0902');
      cancel();
      expect(fcIds, [0x18DA10F1]);
    });
  });

  group('応答の形', () {
    t('H1: ID・PCI・8 バイト', (h, a) {
      h.quiet();
      h.send('ATH1');
      expect(h.send('010C'), '7E8 04 41 0C 0C 80 00 00 00 \r\r>');
    });
    t('VIN（H0）は総バイト数と連番', (h, a) {
      h.quiet();
      expect(
        h.send('0902'),
        '014\r0: 49 02 01 57 41 55 \r1: 5A 5A 5A 38 4B 39 41 \r2: 41 30 30 30 30 30 30 \r\r>',
      );
    });
    t('VIN（H1）は 1 フレーム 1 行', (h, a) {
      h.quiet();
      h.send('ATH1');
      expect(
        h.send('0902'),
        '7E8 10 14 49 02 01 57 41 55 \r7E8 21 5A 5A 5A 38 4B 39 41 \r7E8 22 41 30 30 30 30 30 30 \r\r>',
      );
    });
    t('CFC0 では FC を送らないので最初のフレームで止まる', (h, a) {
      h.quiet();
      h.send('ATCFC0');
      expect(h.send('0902'), '014\r0: 49 02 01 57 41 55 \r\r>');
    });
    t('複数 PID', (h, a) {
      h.quiet();
      expect(h.send('010C0D'), '41 0C 0C 80 0D 00 \r\r>');
      // 応答 8 バイトは 7 を超えるので複数フレーム（設計書 §6.2）
      expect(h.send('010C0D05'), '008\r0: 41 0C 0C 80 0D 00 \r1: 05 7D \r\r>');
    });
    t('トランスミッション有効なら 2 行', (h, a) {
      h.quiet();
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r41 00 80 00 00 01 \r\r>');
    }, transmission: true);
    t('トランスミッション有効時、全 ECU 宛て 0904（CALID）は 2 ECU とも複数フレームで組み立つ', (h, a) {
      h.quiet();
      expect(
        h.send('0904'),
        '013\r'
        '0: 49 04 01 38 4B 30 \r'
        '1: 39 30 37 31 31 35 42 \r'
        '2: 20 20 30 30 31 30 \r'
        '013\r'
        '0: 49 04 01 54 43 4D \r'
        '1: 30 41 57 33 30 30 30 \r'
        '2: 30 30 30 30 31 00 \r'
        '\r>',
      );
    }, transmission: true);
    t('Mode 22: ECU 指定で応答、全 ECU 宛ては NO DATA', (h, a) {
      h.quiet();
      expect(h.send('22F190'), 'NO DATA\r\r>');
      h.send('ATSH7E0');
      expect(
        h.send('22F190'),
        '014\r0: 62 F1 90 57 41 55 \r1: 5A 5A 5A 38 4B 39 41 \r2: 41 30 30 30 30 30 30 \r\r>',
      );
      expect(h.send('221234'), '7F 22 31 \r\r>');
      expect(h.send('1003'), '7F 10 11 \r\r>');
    });
    t('未対応 PID は NO DATA', (h, a) {
      h.quiet();
      expect(h.send('01FF'), 'NO DATA\r\r>');
    });
    t('CRA で 7E9 だけ受けるとエンジンの応答は NO DATA', (h, a) {
      h.quiet();
      h.send('ATCRA7E9');
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
  });

  group('行の解釈', () {
    t('16 進以外・末尾 0・長すぎは ?', (h, a) {
      h.quiet();
      expect(h.send('0XYZ'), '?\r\r>');
      expect(h.send('010'), '?\r\r>');
      expect(h.send('01000C0D050B0E0F'), '?\r\r>'); // 8 バイト（CAF1 は 7 まで）
    });
    t('CAF0 では 8 バイトまで送れる（p.45）', (h, a) {
      h.quiet();
      h.send('ATCAF0');
      expect(h.send('02010C0000000000'), '04 41 0C 0C 80 00 00 00 \r\r>');
    });
    t('空行は直前のコマンドを繰り返す', (h, a) {
      h.quiet();
      h.send('010C');
      h.vehicle.rpm = 2150;
      expect(h.send(''), '41 0C 21 98 \r\r>');
    });
    t('直前のコマンドがない空行は > のみ', (h, a) {
      h.send('ATE0');
      h.session.state.lastCommand = null;
      expect(h.send(''), '>');
    });
    t('ELM327 の分からない入力（DEL 2 つ）は ?（python-OBD の速度判定）', (h, a) {
      h.send('ATE0');
      expect(h.sendRaw('\x7F\x7F\r', untilPrompt: true), '?\r\r>');
    });
  });

  group('タイミング', () {
    t('応答数指定 1 はエンジンの応答（8ms）ですぐ返る', (h, a) {
      h.quiet();
      final d = timed(a, () => expect(h.send('010C1'), '41 0C 0C 80 \r\r>'));
      expect(d, lessThan(const Duration(milliseconds: 12)));
    });
    t('指定なしは最後の応答から 50ms 待つ（AT1）', (h, a) {
      h.quiet();
      final d = timed(a, () => h.send('010C'));
      expect(d.inMilliseconds, inInclusiveRange(58, 60));
    });
    t('AT0 は ST（200ms）まで待つ', (h, a) {
      h.quiet();
      h.send('ATAT0');
      final d = timed(a, () => h.send('010C'));
      expect(d.inMilliseconds, inInclusiveRange(208, 210));
    });
    t('応答がなければ ST で NO DATA、ST19 なら 100ms', (h, a) {
      h.quiet();
      h.send('ATST19');
      final d = timed(a, () => expect(h.send('01FF'), 'NO DATA\r\r>'));
      expect(d.inMilliseconds, inInclusiveRange(100, 102));
    });
    t('R0 は応答を待たない', (h, a) {
      h.quiet();
      h.send('ATR0');
      final d = timed(a, () => expect(h.send('010C'), '\r>'));
      expect(d, Duration.zero);
    });
    t('未確定のまま ATR0: SEARCHING... は出るが established は設定されない（現状の挙動）', (h, a) {
      h.send('ATE0');
      h.send('ATR0');
      expect(h.send('0100'), 'SEARCHING...\r\r>');
      expect(h.session.state.established, isNull);
    });
  });

  group('STOPPED と入力の割り込み', () {
    t('応答待ちに文字が届くと STOPPED', (h, a) {
      h.quiet();
      final out = h.sendRaw(
        '010C\rX',
        elapse: const Duration(milliseconds: 100),
      );
      expect(out, 'STOPPED\r\r>');
      expect(h.session.mode, SessionMode.idle);
    });
    t('LF は応答待ちを止めない（Review Focus 1）', (h, a) {
      h.quiet();
      expect(h.sendRaw('010C\r\n', untilPrompt: true), '41 0C 0C 80 \r\r>');
    });
    t('分割して届いたコマンドを 1 行として扱う（Review Focus 2）', (h, a) {
      h.quiet();
      h.sendRaw('01', elapse: const Duration(milliseconds: 5));
      expect(h.sendRaw('0C\r', untilPrompt: true), '41 0C 0C 80 \r\r>');
    });
    t('AT 2 つを 1 回で送ると両方処理する', (h, a) {
      expect(
        h.sendRaw('ATE0\rATH1\r', elapse: const Duration(milliseconds: 1)),
        'ATE0\rOK\r\r>OK\r\r>',
      );
    });
    t('LP の後は何を送っても応答せず、その次から普通に動く', (h, a) {
      h.send('ATE0');
      expect(h.send('ATLP'), 'OK\r\r>');
      expect(h.session.mode, SessionMode.lowPower);
      expect(h.sendRaw(' ', elapse: const Duration(milliseconds: 10)), '');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
  });

  group('障害', () {
    t('イグニッション OFF: 検索中は UNABLE TO CONNECT、確定後は CAN ERROR', (h, a) {
      h.send('ATE0');
      h.faultConfig.ignitionOff = true;
      expect(h.send('0100'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
      h.faultConfig.ignitionOff = false;
      h.send('0100');
      h.faultConfig.ignitionOff = true;
      expect(h.send('0100'), 'CAN ERROR\r\r>');
    });
    t('ECU 無応答は NO DATA', (h, a) {
      h.quiet();
      h.faultConfig.silentEcus.add('engine');
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
    t('遅延が ST を超えると NO DATA、超えなければ遅れて返る', (h, a) {
      h.quiet();
      h.faultConfig.delayMs = 350;
      expect(h.send('010C'), 'NO DATA\r\r>');
      h.faultConfig.delayMs = 100;
      final d = timed(a, () => expect(h.send('010C1'), '41 0C 0C 80 \r\r>'));
      expect(d.inMilliseconds, inInclusiveRange(108, 110));
    });
    t('欠落 100% は NO DATA', (h, a) {
      h.quiet();
      h.faultConfig.dropPercent = 100;
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
    t('応答保留: 7F 01 78 を表示し、1 秒後の本応答まで待つ', (h, a) {
      h.quiet();
      h.send('ATSH7E0');
      h.faultConfig.responsePending = true;
      final d = timed(
        a,
        () => expect(h.send('010C'), '7F 01 78 \r41 0C 0C 80 \r\r>'),
      );
      expect(d.inMilliseconds, inInclusiveRange(1058, 1060));
    });
    t('途中欠落: 最初のフレームだけ表示して終わる', (h, a) {
      h.quiet();
      h.faultConfig.truncateMultiFrame = true;
      expect(h.send('0902'), '014\r0: 49 02 01 57 41 55 \r\r>');
    });
    t('エラー（次の 1 回）と CS のカウンタ', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.canError
        ..errorArmed = true;
      expect(h.send('010C'), 'CAN ERROR\r\r>');
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
      expect(h.send('ATCS'), 'T:01 R:00\r\r>');
    });
    t('エラー（常に）は解除するまで続く', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.bufferFull
        ..errorTrigger = ErrorTrigger.always
        ..errorArmed = true;
      expect(h.send('010C'), 'BUFFER FULL\r\r>');
      expect(h.send('010C'), 'BUFFER FULL\r\r>');
      h.faultConfig.errorArmed = false;
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
    });
    t('<DATA ERROR は最後のデータ行の横に付く', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.dataErrorMark
        ..errorArmed = true;
      expect(h.send('010C'), '41 0C 0C 80 <DATA ERROR\r\r>');
    });
    t('LV RESET は AT 設定を戻す', (h, a) {
      h.quiet();
      h.send('ATH1');
      h.faultConfig
        ..error = ElmErrorKind.lvReset
        ..errorArmed = true;
      expect(h.send('010C'), 'LV RESET\r\r>');
      expect(h.session.state.headers, isFalse);
      expect(h.session.state.echo, isTrue);
    });
    t('応答待ち中に障害を切り替えても必ず終わる（Review Focus 3）', (h, a) {
      h.quiet();
      h.faultConfig.delayMs = 100;
      final out = StringBuffer();
      out.write(h.sendRaw('010C\r', elapse: const Duration(milliseconds: 50)));
      h.faultConfig.silentEcus.add('engine');
      out.write(h.sendRaw('', elapse: const Duration(milliseconds: 300)));
      expect(out.toString(), 'NO DATA\r\r>');
      expect(h.session.mode, SessionMode.idle);
    });
  });

  t('BD は最後に受信したフレーム', (h, a) {
    h.quiet();
    h.send('010C');
    expect(h.send('ATBD'), '0A 07 E8 04 41 0C 0C 80 00 00 00 00 00\r\r>');
  });

  t('dispose 後は出力しない（Review Focus 4）', (h, a) {
    h.quiet();
    final before = h.all.length;
    h.session.input('010C\r'.codeUnits);
    h.session.dispose();
    a.elapse(const Duration(seconds: 1));
    expect(h.all.length, before);
    h.session.input('ATI\r'.codeUnits); // 例外にならない
  });

  t('監視中は何か受信すると STOPPED（中身は Task 11）', (h, a) {
    h.quiet();
    expect(h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 5)), '');
    expect(h.session.mode, SessionMode.monitoring);
    expect(
      h.sendRaw('X', elapse: const Duration(milliseconds: 1)),
      'STOPPED\r\r>',
    );
  });

  group('周期フレームと受信フィルタ（最終レビュー I1・I2）', () {
    PeriodicTraffic traffic(ElmHarness h) =>
        PeriodicTraffic(h.bus, h.vehicle, h.faults)..start();

    t('RA C9 で待ち中に 0C9 が FF・CF の形になっても例外にならない（crash2）', (h, a) {
      final p = traffic(h);
      h.vehicle.rpm = 1024; // 0C9 の先頭 2 バイトが 10 00（宣言長 0 の FF）
      h.send('ATE0');
      h.send('ATSP6');
      h.send('ATRAC9');
      h.send('ATSTFF');
      h.sendRaw('0100\r', elapse: const Duration(milliseconds: 150));
      h.vehicle.rpm = 2112; // 21 00（連番 1 の CF）
      final out = h.sendRaw('', elapse: const Duration(milliseconds: 1200));
      expect(out, endsWith('>'));
      expect(h.session.mode, SessionMode.idle);
      p.stop();
    });

    for (final headers in [false, true]) {
      final hn = headers ? 'H1' : 'H0';
      t('$hn: CF000 + CM000 でも周期フレームを応答に数えず 0100 が返る', (h, a) {
        final p = traffic(h);
        h.vehicle.rpm = 2112;
        h.send('ATE0');
        h.send('ATSP6');
        h.send(headers ? 'ATH1' : 'ATH0');
        h.send('ATCF000');
        h.send('ATCM000');
        final d = timed(
          a,
          () => expect(
            h.send('0100'),
            headers
                ? '7E8 06 41 00 BE 3F A0 13 00 \r\r>'
                : '41 00 BE 3F A0 13 \r\r>',
          ),
        );
        expect(d.inMilliseconds, inInclusiveRange(58, 60));
        p.stop();
      });
      for (final filter in ['ATCRA0C9', 'ATRAC9']) {
        t('$hn: $filter では 7E8 がフィルタで落ち、ST ちょうどで NO DATA', (h, a) {
          final p = traffic(h);
          h.send('ATE0');
          h.send('ATSP6');
          h.send(headers ? 'ATH1' : 'ATH0');
          h.send(filter);
          final d = timed(a, () => expect(h.send('0100'), 'NO DATA\r\r>'));
          expect(d.inMilliseconds, inInclusiveRange(200, 202));
          p.stop();
        });
      }
    }

    t('監視中は周期フレームを従来どおり表示する', (h, a) {
      final p = traffic(h);
      h.send('ATE0');
      h.send('ATSP6');
      h.send('ATH1');
      final out = h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 25));
      expect(out, contains('0C9 '));
      p.stop();
    });
  });
}
