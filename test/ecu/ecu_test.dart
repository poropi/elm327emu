import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/iso_tp.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/ecu/ecu.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/uds_services.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

class _Bench {
  _Bench() {
    for (final p in [engine, tcm]) {
      final e = Ecu(
        profile: p,
        bus: bus,
        obd: obd,
        uds: UdsServices(),
        faults: faults,
      );
      ecus.add(e);
      bus.attach(e);
    }
    bus.listen((e) {
      if (!identical(e.sender, tester)) got.add(e.frame);
    });
  }
  final bus = VirtualCanBus();
  final v = VehicleState.defaults();
  late final obd = ObdServices(v);
  final cfg = FaultConfig();
  late final faults = FaultInjector(cfg);
  final engine = EcuProfile.engine();
  final tcm = EcuProfile.transmission();
  final tester = Object();
  final got = <CanFrame>[];
  final ecus = <Ecu>[];

  void send(int id, List<int> payload, {bool ext = false}) => bus.transmit(
    CanFrame(id, segment(payload).single, extended: ext),
    sender: tester,
  );
}

List<int> _pad(List<int> d) => [...d, ...List.filled(8 - d.length, 0)];

void main() {
  test('全 ECU 宛て 010C にエンジンが 8ms 後に応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7DF, [0x01, 0x0C]);
      async.elapse(const Duration(milliseconds: 7));
      expect(b.got, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got, [
        CanFrame(0x7E8, _pad([0x04, 0x41, 0x0C, 0x0C, 0x80])),
      ]);
    });
  });

  test('トランスミッションを有効にすると 15ms 後に 7E9 も応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.tcm.enabled = true;
      b.send(0x7DF, [0x01, 0x00]);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got.map((f) => f.id), [0x7E8, 0x7E9]);
      expect(b.got[1].data, _pad([0x06, 0x41, 0x00, 0x80, 0x00, 0x00, 0x01]));
    });
  });

  test('遅延応答の予約後に dispose すると、時間を進めても送信されない', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x01, 0x0C]);
      async.elapse(const Duration(milliseconds: 4)); // 8ms 遅延の途中で dispose する
      expect(b.got, isEmpty);
      b.ecus.first.dispose();
      async.elapse(const Duration(seconds: 2));
      expect(b.got, isEmpty);
    });
  });

  test('物理アドレス 7E0 にはエンジンだけ、7E1 は無効なので無応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x01, 0x0D]);
      b.send(0x7E1, [0x01, 0x00]);
      async.elapse(const Duration(milliseconds: 50));
      expect(b.got.map((f) => f.id), [0x7E8]);
    });
  });

  test('29bit の全 ECU 宛て・物理アドレス', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x18DB33F1, [0x01, 0x0C], ext: true);
      b.send(0x18DA10F1, [0x01, 0x0D], ext: true);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got.map((f) => f.id), [0x18DAF110, 0x18DAF110]);
      expect(b.got.every((f) => f.extended), isTrue);
    });
  });

  test('複数フレームは FC を受けてから CF を 1ms 間隔で送る', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 8));
      expect(b.got.single.data.sublist(0, 2), [0x10, 0x14]);
      async.elapse(const Duration(milliseconds: 100));
      expect(b.got.length, 1); // FC を送るまで待つ
      b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got.length, 2);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got.map((f) => f.data[0]), [0x10, 0x21, 0x22]);
    });
  });

  test('FC のブロックサイズ 1 なら 1 フレームごとに FC を待つ', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 8));
      b.bus.transmit(
        CanFrame(0x7E0, flowControl(blockSize: 1)),
        sender: b.tester,
      );
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 2);
      b.bus.transmit(
        CanFrame(0x7E0, flowControl(blockSize: 1)),
        sender: b.tester,
      );
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 3);
    });
  });

  test('FC が 1000ms 来なければ送信を諦める', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 1100));
      b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 1);
    });
  });

  group('障害', () {
    test('ECU 無応答', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.silentEcus.add('engine');
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.got, isEmpty);
      });
    });
    test('遅延は基本遅延に加算', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.delayMs = 100;
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 107));
        expect(b.got, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(b.got.length, 1);
      });
    });
    test('応答保留: 物理アドレスには 7F SID 78 → 1000ms 後に本応答', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.responsePending = true;
        b.send(0x7E0, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 8));
        expect(b.got.single.data, _pad([0x03, 0x7F, 0x01, 0x78]));
        async.elapse(const Duration(milliseconds: 1000));
        expect(b.got[1].data, _pad([0x04, 0x41, 0x0C, 0x0C, 0x80]));
      });
    });
    test('応答保留は全 ECU 宛てには効かない', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.responsePending = true;
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 8));
        expect(b.got.single.data[1], 0x41);
      });
    });
    test('途中欠落: FF のみで CF は送らない', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.truncateMultiFrame = true;
        b.send(0x7E0, [0x09, 0x02]);
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.got.length, 1);
      });
    });
  });

  test('Mode 22 は物理アドレスで応答し、全 ECU 宛てには黙る', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7DF, [0x22, 0xF1, 0x87]);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got, isEmpty);
      b.send(0x7E0, [0x22, 0xF1, 0x87]);
      async.elapse(const Duration(milliseconds: 8));
      expect(b.got.single.data.sublist(0, 2), [0x10, 0x0D]);
    });
  });

  test('RTR と SF 以外は無視', () {
    fakeAsync((async) {
      final b = _Bench();
      b.bus.transmit(CanFrame(0x7DF, [], rtr: true), sender: b.tester);
      b.bus.transmit(CanFrame(0x7DF, [0x21, 1, 2]), sender: b.tester);
      async.elapse(const Duration(milliseconds: 50));
      expect(b.got, isEmpty);
    });
  });

  group('要求者ごとの分離（最終レビュー I3）', () {
    test('応答（SF・FF・CF・7F 78）はすべて要求した送信元を replyTo に持つ', () {
      fakeAsync((async) {
        final b = _Bench();
        final events = <BusEvent>[];
        b.bus.listen((e) {
          if (e.sender is Ecu) events.add(e);
        });
        b.send(0x7DF, [0x01, 0x0C]);
        b.send(0x7E0, [0x09, 0x02]);
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
        async.elapse(const Duration(milliseconds: 10));
        b.cfg.responsePending = true;
        b.send(0x7E0, [0x01, 0x0D]);
        async.elapse(const Duration(milliseconds: 1100));
        expect(events.map((e) => e.frame.data[0] >> 4), [0, 1, 2, 2, 0, 0]);
        expect(events.every((e) => identical(e.replyTo, b.tester)), isTrue);
      });
    });

    test('FC は、その FC を送った要求者への送信にだけ効く', () {
      fakeAsync((async) {
        final b = _Bench();
        final other = Object();
        b.send(0x7E0, [0x09, 0x02]);
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: other);
        async.elapse(const Duration(milliseconds: 10));
        Iterable<int> pci() =>
            b.got.where((f) => f.id == 0x7E8).map((f) => f.data[0]);
        expect(pci(), [0x10]); // 他の要求者の FC では CF を出さない
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
        async.elapse(const Duration(milliseconds: 10));
        expect(pci(), [0x10, 0x21, 0x22]);
      });
    });

    test('2 つの要求者の複数フレームを並行して送り、それぞれの FC で進む', () {
      fakeAsync((async) {
        final b = _Bench();
        final other = Object();
        final byReplyTo = <Object?, List<int>>{};
        b.bus.listen((e) {
          if (e.sender is Ecu) {
            (byReplyTo[e.replyTo] ??= []).add(e.frame.data[0]);
          }
        });
        b.send(0x7E0, [0x09, 0x02]);
        b.bus.transmit(
          CanFrame(0x7E0, segment([0x09, 0x04]).single),
          sender: other,
        );
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: other);
        async.elapse(const Duration(milliseconds: 10));
        expect(byReplyTo[b.tester], [0x10]);
        expect(byReplyTo[other], [0x10, 0x21, 0x22]);
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
        async.elapse(const Duration(milliseconds: 10));
        expect(byReplyTo[b.tester], [0x10, 0x21, 0x22]);
        expect(b.ecus.first.pendingTransfers, 0);
      });
    });

    test('FC が来ないまま 1000ms 経った送信状態は捨てる（リークしない）', () {
      fakeAsync((async) {
        final b = _Bench();
        b.send(0x7E0, [0x09, 0x02]);
        b.bus.transmit(
          CanFrame(0x7E0, segment([0x09, 0x04]).single),
          sender: Object(),
        );
        async.elapse(const Duration(milliseconds: 8));
        expect(b.ecus.first.pendingTransfers, 2);
        async.elapse(const Duration(milliseconds: 1000));
        expect(b.ecus.first.pendingTransfers, 0);
      });
    });

    test('dispose はすべての要求者の送信を止める', () {
      fakeAsync((async) {
        final b = _Bench();
        final other = Object();
        b.send(0x7E0, [0x09, 0x02]);
        b.bus.transmit(
          CanFrame(0x7E0, segment([0x09, 0x04]).single),
          sender: other,
        );
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(
          CanFrame(0x7E0, flowControl(stMin: 5)),
          sender: b.tester,
        );
        b.bus.transmit(CanFrame(0x7E0, flowControl(stMin: 5)), sender: other);
        async.elapse(const Duration(milliseconds: 6));
        final before = b.got.length;
        b.ecus.first.dispose();
        async.elapse(const Duration(seconds: 2));
        expect(b.got.length, before);
        expect(b.ecus.first.pendingTransfers, 0);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
