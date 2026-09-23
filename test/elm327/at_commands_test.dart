import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/elm327/at_commands.dart';
import 'package:elm327emu/elm327/elm_state.dart';

void main() {
  late ElmState s;
  late AtCommands at;
  var volts = 12.4;
  var ignition = true;
  setUp(() {
    s = ElmState();
    volts = 12.4;
    ignition = true;
    at = AtCommands(s, voltage: () => volts, ignitionOn: () => ignition);
  });

  List<String> reply(String body, {String raw = ''}) {
    final o = at.handle(body, raw: raw);
    expect(o, isA<AtReply>(), reason: body);
    return (o as AtReply).lines;
  }

  void ok(String body) => expect(reply(body), ['OK'], reason: body);
  void q(String body) => expect(reply(body), ['?'], reason: body);

  group('全般', () {
    test('Z / WS は reset して AtReset', () {
      s.echo = false;
      expect(at.handle('Z'), isA<AtReset>());
      expect(s.echo, isTrue);
      s.headers = true;
      expect(at.handle('WS'), isA<AtReset>());
      expect(s.headers, isFalse);
    });
    test('D は初期値に戻して OK', () {
      s.headers = true;
      ok('D');
      expect(s.headers, isFalse);
    });
    test('I / @1', () {
      expect(reply('I'), [elmId]);
      expect(reply('@1'), [elmDescription]);
    });
    test('@2 は未保存なら ?、@3 は 12 文字ちょうどを 1 回だけ保存（p.26）', () {
      q('@2');
      expect(reply('@3SHORT', raw: 'AT@3 SHORT'), ['?']);
      expect(reply('@3ABCDEFGHIJKLM', raw: 'AT@3 ABCDEFGHIJKLM'), ['?']); // 13 文字
      // スペースと小文字はそのまま保存する（'SN-001 2026x' は 12 文字）
      expect(reply('@3SN-0012026X', raw: 'AT@3 SN-001 2026x'), ['OK']);
      expect(reply('@2'), ['SN-001 2026x']);
      expect(reply('@3OTHER0000000', raw: 'AT@3 OTHER0000000'), ['?']); // 2 回目
    });
    test('E / L / M / H / S / R / V / D0/1 / CAF / CFC', () {
      ok('E0');
      expect(s.echo, isFalse);
      ok('L1');
      expect(s.linefeed, isTrue);
      ok('M0');
      expect(s.memory, isFalse);
      ok('H1');
      expect(s.headers, isTrue);
      ok('S0');
      expect(s.spaces, isFalse);
      ok('R0');
      expect(s.responses, isFalse);
      ok('V1');
      expect(s.variableDlc, isTrue);
      ok('D1');
      expect(s.dlc, isTrue);
      ok('CAF0');
      expect(s.caf, isFalse);
      ok('CFC0');
      expect(s.autoFlowControl, isFalse);
      q('E2');
    });
    test('SD / RD', () {
      ok('SD5A');
      expect(reply('RD'), ['5A']);
    });
    test('BRD は 00 以外 OK（p.12）、BRT / FE は OK', () {
      ok('BRD23');
      q('BRD00');
      ok('BRT0F');
      ok('FE');
    });
    test('LP は AtLowPower', () {
      expect(at.handle('LP'), isA<AtLowPower>());
    });
    test('PP と PPS（番号:値 N/F、1 行 4 項目、00〜2F）', () {
      ok('PP0CSV68');
      ok('PP0CON');
      ok('PPFFOFF');
      expect(s.ppEnabled, isEmpty);
      ok('PP0CON');
      final lines = reply('PPS');
      expect(lines.length, 12);
      expect(lines.first, '00:FF F  01:FF F  02:FF F  03:FF F');
      expect(lines[3], '0C:68 N  0D:FF F  0E:FF F  0F:FF F');
      expect(lines[9].startsWith('24:FF F  25:FF F  26:00 F'), isTrue);
      ok('PPFFON');
      expect(s.ppEnabled.length, 0x30);
      ok('PP0COFF');
      expect(s.ppEnabled.contains(0x0C), isFalse);
    });
    test('RV は車両電圧、CV で補正、CV 0000 で解除', () {
      expect(reply('RV'), ['12.4V']);
      ok('CV1250');
      expect(reply('RV'), ['12.5V']);
      volts = 13.0;
      expect(reply('RV'), ['13.1V']);
      ok('CV0000');
      expect(reply('RV'), ['13.0V']);
    });
    test('IGN', () {
      expect(reply('IGN'), ['ON']);
      ignition = false;
      expect(reply('IGN'), ['OFF']);
    });
  });

  group('OBD 全般', () {
    test('AL / NL', () {
      ok('AL');
      expect(s.allowLong, isTrue);
      ok('NL');
      expect(s.allowLong, isFalse);
    });
    test('AMC は最後の通信からの経過（0.65536 秒単位、上限 FF）、AMT は保存', () {
      withClock(Clock.fixed(DateTime(2026, 1, 1, 0, 0, 10)), () {
        s.lastActivity = DateTime(2026, 1, 1, 0, 0, 0);
        expect(reply('AMC'), ['0F']); // 10 / 0.65536 = 15.2
        s.lastActivity = DateTime(2025, 1, 1);
        expect(reply('AMC'), ['FF']);
        s.lastActivity = null;
        expect(reply('AMC'), ['FF']);
      });
      ok('AMT20');
      expect(s.activityTimeout, 0x20);
    });
    test('AR は受信アドレスを解除、RA / SR は設定', () {
      ok('RAE9');
      expect(s.receiveAddress, 0xE9);
      ok('AR');
      expect(s.receiveAddress, isNull);
      ok('SRE8');
      expect(s.receiveAddress, 0xE8);
    });
    test('AT0 / AT1 / AT2', () {
      ok('AT0');
      expect(s.timing, AdaptiveTiming.off);
      ok('AT2');
      expect(s.timing, AdaptiveTiming.auto2);
      q('AT3');
    });
    test('BD は長さ + 12 バイト', () {
      expect(reply('BD'), ['00 00 00 00 00 00 00 00 00 00 00 00 00']);
      s.lastFrame = CanFrame(0x7E8, [0x04, 0x41, 0x0C, 0x21, 0x98, 0, 0, 0]);
      expect(reply('BD'), ['0A 07 E8 04 41 0C 21 98 00 00 00 00 00']);
    });
    test('BI / PC / SS は OK', () {
      ok('BI');
      ok('PC');
      ok('SS');
    });
    test('DP / DPN', () {
      expect(reply('DP'), ['AUTO']);
      expect(reply('DPN'), ['A0']);
      ok('SP6');
      expect(reply('DP'), ['ISO 15765-4 (CAN 11/500)']);
      expect(reply('DPN'), ['6']);
    });
    test('MA / MR / MT は AtMonitor', () {
      expect(at.handle('MA'), isA<AtMonitor>());
      final mr = at.handle('MR07') as AtMonitor;
      expect(mr.receiver, 0x07);
      final mt = at.handle('MTC9') as AtMonitor;
      expect(mt.transmitter, 0xC9);
    });
    test('SH は 3 / 6 / 8 桁、それ以外は ?', () {
      ok('SH7E0');
      expect(s.header, 0x7E0);
      ok('SHDA10F1');
      expect(s.header, 0xDA10F1);
      ok('SH1BDA10F1');
      expect(s.priority29, 0x1B);
      expect(s.header, 0xDA10F1);
      q('SH7E');
      q('SH');
    });
    test('SP / SPA / SP00 / TP / TPA（保存するかどうか）', () {
      ok('SP7');
      expect(s.storedProtocol, 7);
      expect(s.autoSearch, isFalse);
      ok('SP0');
      expect(s.autoSearch, isTrue);
      expect(s.storedProtocol, 7); // SP 0 は保存しない
      ok('SPA8');
      expect(s.storedProtocol, 8);
      expect(s.storedAuto, isTrue);
      ok('SP00');
      expect(s.storedProtocol, 0);
      ok('TP9');
      expect(s.protocol, 9);
      expect(s.storedProtocol, 0);
      ok('TPA6');
      expect(s.autoSearch, isTrue);
      q('SP');
      q('SPD');
    });
    test('ST は ×4ms、00 は初期値', () {
      ok('ST19');
      expect(s.timeout, const Duration(milliseconds: 100));
      ok('ST00');
      expect(s.timeoutHex, 0x32);
    });
    test('TA', () {
      ok('TAF2');
      expect(s.testerAddress, 0xF2);
    });
  });

  group('CAN', () {
    test('CEA / CEA hh', () {
      ok('CEA05');
      expect(s.extendedAddress, 0x05);
      ok('CEA');
      expect(s.extendedAddress, isNull);
    });
    test('CF / CM（3 桁・8 桁）', () {
      ok('CF7E8');
      ok('CM7FE');
      expect(s.filterId, 0x7E8);
      expect(s.maskId, 0x7FE);
      ok('CF18DAF110');
      ok('CM1FFFFFFF');
      expect(s.filterId, 0x18DAF110);
      q('CF7E');
    });
    test('CP / CRA / CS / CSM', () {
      ok('CP1B');
      expect(s.priority29, 0x1B);
      ok('CRA7E9');
      expect(s.craId, 0x7E9);
      ok('CRA18DAF110');
      expect(s.craId, 0x18DAF110);
      ok('CF7E8');
      ok('CM7FF');
      ok('CRA');
      expect(s.craId, isNull);
      expect(s.maskId, isNull);
      s.txErrors = 3;
      expect(reply('CS'), ['T:03 R:00']);
      ok('CSM0');
    });
    test('FC SM は 0〜2、1 と 2 は必要なデータがないと ?（p.15）', () {
      ok('FCSM0');
      q('FCSM1');
      q('FCSM2');
      ok('FCSD300000');
      ok('FCSM2');
      q('FCSM1');
      ok('FCSH7E0');
      ok('FCSM1');
      expect(s.flowMode, 1);
      q('FCSM3');
      q('FCSD');
      ok('FCSH18DA10F1');
    });
    test('PB は OK、RTR は AtRtr', () {
      ok('PBC001');
      expect(at.handle('RTR'), isA<AtRtr>());
    });
  });

  group('CAN 以外', () {
    test('設定系は OK', () {
      for (final c in [
        'IFR0', 'IFR1', 'IFR2', 'IFRH', 'IFRS', 'IB10', 'IB48', 'IB96', 'IIA13', //
        'KW0', 'KW1', 'SW92', 'SW00', 'WM8110F13E', 'JE', 'JS', 'JHF0', 'JHF1', 'JTM1', 'JTM5',
      ]) {
        ok(c);
      }
    });
    test('実行系は ?（p.78）', () {
      for (final c in ['FI', 'SI', 'KW', 'DM1', 'MPFECA', 'MPFECA5', 'MP00FECA', 'MP00FECA3']) {
        q(c);
      }
    });
  });

  test('未知・空は ?', () {
    q('XYZ');
    q('');
    q('E');
  });
}
