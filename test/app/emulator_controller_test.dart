import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/transport/transport.dart';
import '../support/fake_bridge.dart';

void main() {
  (EmulatorController, FakeTransportBridge) make(FakeAsync async) {
    final bridge = FakeTransportBridge();
    final c = EmulatorController(bridge: bridge, tcpAvailable: false);
    c.init();
    async.flushMicrotasks();
    return (c, bridge);
  }

  void rx(FakeTransportBridge b, TransportType t, String s) =>
      b.rx.add((transport: t, bytes: s.codeUnits));

  test('受信を接続ごとのセッションに渡し、応答を送り返す', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      expect(c.caps, [TransportType.ble, TransportType.spp]);
      rx(b, TransportType.ble, 'ATE0\r');
      rx(b, TransportType.spp, 'ATI\r');
      async.elapse(const Duration(milliseconds: 1));
      expect(b.sentText(TransportType.ble), 'ATE0\rOK\r\r>');
      expect(b.sentText(TransportType.spp), 'ATI\rELM327 v1.5\r\r>');
      expect(
        c.sessions.keys,
        containsAll([TransportType.ble, TransportType.spp]),
      );
      expect(c.displayState.echo, isTrue); // 最後に受信したのは SPP（エコーあり）
      c.dispose();
    });
  });

  test('ログに送受信と CAN フレームが残る（周期フレームは残さない）', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      rx(b, TransportType.ble, 'ATE0\r0100\r');
      async.elapse(const Duration(milliseconds: 500));
      final kinds = c.log.map((e) => e.kind).toSet();
      expect(kinds, containsAll([LogKind.input, LogKind.output, LogKind.can]));
      expect(
        c.log
            .where((e) => e.kind == LogKind.can)
            .any((e) => e.text.contains('0C9')),
        isFalse,
      );
      expect(
        c.log.firstWhere((e) => e.kind == LogKind.input).text,
        r'ATE0\r0100\r',
      );
      c.dispose();
    });
  });

  test('切断イベントでセッションを破棄する（Review Focus 4）', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      rx(b, TransportType.ble, 'ATE0\r');
      async.elapse(const Duration(milliseconds: 1));
      b.conn.add((
        transport: TransportType.ble,
        state: 'connected',
        device: 'AA',
      ));
      expect(c.connState[TransportType.ble], '接続中 · AA');
      expect(c.headlineStatus, 'BLE 接続中');
      b.conn.add((
        transport: TransportType.ble,
        state: 'disconnected',
        device: 'AA',
      ));
      expect(c.sessions.containsKey(TransportType.ble), isFalse);
      expect(c.connState[TransportType.ble], '待ち受け中');
      async.elapse(const Duration(seconds: 1));
      c.dispose();
    });
  });

  test('障害・DTC・ECU の操作', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.updateFaults((f) => f.delayMs = 350);
      expect(c.activeFaultDescriptions(), ['応答の遅延 350ms']);
      expect(c.log.last.kind, LogKind.fault);
      expect(c.addDtc(c.core.engine, DtcKind.confirmed, ' p0420 '), isTrue);
      expect(c.core.engine.confirmedDtcs, ['P0301', 'P0420']);
      expect(c.addDtc(c.core.engine, DtcKind.pending, 'X1'), isFalse);
      c.addDtc(c.core.engine, DtcKind.permanent, 'P0301');
      c.clearDtcs(c.core.engine);
      expect(c.core.engine.confirmedDtcs, isEmpty);
      expect(c.core.engine.permanentDtcs, ['P0301']);
      c.setEcuEnabled(c.core.transmission, true);
      expect(c.core.transmission.enabled, isTrue);
      expect(
        c.updateEcuInfo(
          c.core.engine,
          vin: 'SHORT',
          calid: 'X',
          cvnHex: '1A2B3C4D',
          name: 'ECM',
        ),
        isNotNull,
      );
      expect(
        c.updateEcuInfo(
          c.core.engine,
          vin: 'JT2BF22K1W0123456',
          calid: 'CAL1',
          cvnHex: '01020304',
          name: 'ECM-Test',
        ),
        isNull,
      );
      expect(c.core.engine.vin, 'JT2BF22K1W0123456');
      expect(c.core.engine.cvn, [1, 2, 3, 4]);
      c.setDid(c.core.engine, 0x1234, DidValue.ascii('AB'));
      expect(c.core.engine.dids[0x1234]!.display, 'AB');
      c.removeDid(c.core.engine, 0x1234);
      expect(c.core.engine.dids.containsKey(0x1234), isFalse);
      c.updateFaults((f) {
        f.error = ElmErrorKind.canError;
        f.errorArmed = true;
      });
      expect(c.activeFaultDescriptions().last, 'エラー応答 CAN ERROR（次の1回）');
      c.dispose();
    });
  });

  test('BLE の開始・切断はブリッジへ渡す', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.setBleProfile(true);
      c.startBle();
      c.disconnect(TransportType.ble);
      async.flushMicrotasks();
      expect(b.calls, ['startBle:true', 'disconnect:ble']);
      expect(c.statusText(TransportType.ble), '待ち受け中');
      c.dispose();
    });
  });

  test(
    'disconnect はブリッジの MissingPluginException/PlatformException を捕まえて info ログにする',
    () {
      fakeAsync((async) {
        final (c, b) = make(async);
        c.startBle();
        c.startSpp();
        async.flushMicrotasks();

        b.disconnectErrors[TransportType.ble] = MissingPluginException(
          'elm327/control#disconnect',
        );
        c.disconnect(TransportType.ble);
        async.flushMicrotasks();
        expect(c.log.last.kind, LogKind.info);
        expect(c.log.last.text, contains('BLE'));

        b.disconnectErrors[TransportType.spp] = PlatformException(code: 'boom');
        c.disconnect(TransportType.spp);
        async.flushMicrotasks();
        expect(c.log.last.kind, LogKind.info);
        expect(c.log.last.text, contains('SPP'));
        c.dispose();
      });
    },
  );

  test('disconnectAll は1つが例外を投げても残りの transport を切断する', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.startBle();
      c.startSpp();
      async.flushMicrotasks();
      b.conn.add((
        transport: TransportType.ble,
        state: 'connected',
        device: 'AA',
      ));
      b.conn.add((
        transport: TransportType.spp,
        state: 'connected',
        device: 'BB',
      ));

      b.disconnectErrors[TransportType.ble] = PlatformException(code: 'boom');
      c.disconnectAll();
      async.flushMicrotasks();
      expect(b.calls, containsAll(['disconnect:ble', 'disconnect:spp']));
      c.dispose();
    });
  });

  test('停止済みの transport に遅れて届いた disconnected イベントは待ち受け中に戻さない', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.startBle();
      async.flushMicrotasks();
      b.conn.add((
        transport: TransportType.ble,
        state: 'connected',
        device: 'AA',
      ));
      c.stopBle();
      async.flushMicrotasks();
      expect(c.connState.containsKey(TransportType.ble), isFalse);

      // ネイティブ側から遅れて届いた切断イベント。
      b.conn.add((
        transport: TransportType.ble,
        state: 'disconnected',
        device: 'AA',
      ));
      expect(c.connState.containsKey(TransportType.ble), isFalse);
      c.dispose();
    });
  });
}
