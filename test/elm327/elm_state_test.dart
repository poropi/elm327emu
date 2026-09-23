import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/elm327/elm_state.dart';

void main() {
  late ElmState s;
  setUp(() => s = ElmState());

  test('初期値', () {
    expect(s.echo, isTrue);
    expect(s.linefeed, isFalse);
    expect(s.spaces, isTrue);
    expect(s.headers, isFalse);
    expect(s.caf, isTrue);
    expect(s.protocol, 0);
    expect(s.autoSearch, isTrue);
    expect(s.timeout, const Duration(milliseconds: 200));
    expect(s.timing, AdaptiveTiming.auto1);
    expect(s.txId, 0x7DF);
  });

  group('プロトコル', () {
    test('未確定の自動は AUTO / A0、確定後は AUTO, 名前 / A6', () {
      expect(s.describeProtocol(), 'AUTO');
      expect(s.describeProtocolNumber(), 'A0');
      expect(s.activeProtocol, 6);
      s.established = 6;
      expect(s.describeProtocol(), 'AUTO, ISO 15765-4 (CAN 11/500)');
      expect(s.describeProtocolNumber(), 'A6');
    });
    test('固定の 7 は 29bit、名前だけ', () {
      s.setProtocol(7, auto: false, save: true);
      expect(s.is29bit, isTrue);
      expect(s.describeProtocol(), 'ISO 15765-4 (CAN 29/500)');
      expect(s.describeProtocolNumber(), '7');
    });
    test('自動で CAN 以外から始めても送信は 6（11bit）', () {
      s.setProtocol(3, auto: true, save: false);
      expect(s.activeProtocol, 6);
      expect(s.describeProtocol(), 'AUTO, ISO 9141-2');
    });
    test('固定の CAN 以外は activeProtocol もそのまま', () {
      s.setProtocol(3, auto: false, save: false);
      expect(s.activeProtocol, 3);
      expect(ElmState.isCanProtocol(s.activeProtocol), isFalse);
    });
    test('プロトコルを変えると確定は解除', () {
      s.established = 6;
      s.setProtocol(8, auto: false, save: false);
      expect(s.established, isNull);
    });
    test('保存したプロトコルは reset / defaults の後も残る（p.13, p.24）', () {
      s.setProtocol(7, auto: false, save: true);
      s.reset();
      expect(s.protocol, 7);
      expect(s.autoSearch, isFalse);
      s.setProtocol(8, auto: false, save: false); // TP 相当
      s.defaults();
      expect(s.protocol, 7);
    });
  });

  group('送信 ID', () {
    test('29bit の既定は 18DB33F1', () {
      s.setProtocol(7, auto: false, save: false);
      expect(s.txId, 0x18DB33F1);
    });
    test('SH 7E0 は 11bit ID', () {
      s.header = 0x7E0;
      expect(s.txId, 0x7E0);
    });
    test('SH DA10F1 と CP で 29bit ID', () {
      s.setProtocol(7, auto: false, save: false);
      s.header = 0xDA10F1;
      expect(s.txId, 0x18DA10F1);
      s.priority29 = 0x1B;
      expect(s.txId, 0x1BDA10F1);
    });
    test('TA で既定の 29bit 送信元が変わる', () {
      s.setProtocol(7, auto: false, save: false);
      s.testerAddress = 0xF2;
      expect(s.txId, 0x18DB33F2);
    });
  });

  group('受信フィルタ', () {
    CanFrame f(int id, {bool ext = false}) => CanFrame(id, [0], extended: ext);
    test('既定: 11bit は 7E8〜7EF のみ', () {
      expect(s.acceptsResponse(f(0x7E8)), isTrue);
      expect(s.acceptsResponse(f(0x7EF)), isTrue);
      expect(s.acceptsResponse(f(0x7E0)), isFalse);
      expect(s.acceptsResponse(f(0x0C9)), isFalse);
      expect(s.acceptsResponse(f(0x18DAF110, ext: true)), isFalse);
    });
    test('既定: 29bit は 18DAF1xx', () {
      s.setProtocol(7, auto: false, save: false);
      expect(s.acceptsResponse(f(0x18DAF110, ext: true)), isTrue);
      expect(s.acceptsResponse(f(0x18DAF210, ext: true)), isFalse);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('CRA は ID 完全一致', () {
      s.craId = 0x7E9;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('CF / CM', () {
      s
        ..filterId = 0x7E8
        ..maskId = 0x7FE;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7EA)), isFalse);
    });
    test('RA: 11bit は下位 8bit', () {
      s.receiveAddress = 0xE9;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('監視: 既定のフィルタは使わず全部通す。MR / MT で絞る', () {
      expect(s.acceptsMonitor(f(0x0C9)), isTrue);
      expect(s.acceptsMonitor(f(0x0C9), transmitter: 0xC9), isTrue);
      expect(s.acceptsMonitor(f(0x3E9), transmitter: 0xC9), isFalse);
      expect(s.acceptsMonitor(f(0x7E8), receiver: 0x07), isTrue);
      expect(s.acceptsMonitor(f(0x18DAF110, ext: true)), isFalse); // 11bit 中
    });
  });

  test('reset は表示設定と実行時状態を戻し、保存値（@3・SD・PP・CV）は残す', () {
    s
      ..echo = false
      ..headers = true
      ..header = 0x7E0
      ..timeoutHex = 0x10
      ..lastCommand = '010C'
      ..txErrors = 3
      ..deviceId = 'ABCDEFGHIJKL'
      ..storedByte = 0x5A
      ..voltageOffset = 0.3;
    s.ppValues[0x0C] = 0x68;
    s.reset();
    expect(s.echo, isTrue);
    expect(s.headers, isFalse);
    expect(s.header, isNull);
    expect(s.timeoutHex, 0x32);
    expect(s.lastCommand, isNull);
    expect(s.txErrors, 0);
    expect(s.deviceId, 'ABCDEFGHIJKL');
    expect(s.storedByte, 0x5A);
    expect(s.voltageOffset, 0.3);
    expect(s.ppValues[0x0C], 0x68);
  });

  test('defaults は lastCommand を残す', () {
    s.lastCommand = '010C';
    s.defaults();
    expect(s.lastCommand, '010C');
  });
}
