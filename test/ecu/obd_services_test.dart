import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/pid_table.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late VehicleState v;
  late EcuProfile engine;
  late EcuProfile tcm;
  late ObdServices obd;
  setUp(() {
    v = VehicleState.defaults();
    engine = EcuProfile.engine();
    tcm = EcuProfile.transmission();
    obd = ObdServices(v);
  });

  group('Mode 01', () {
    test('単一 PID', () {
      expect(obd.handle([0x01, 0x0C], engine), [0x41, 0x0C, 0x0C, 0x80]);
    });
    test('複数 PID は対応分だけ順に並べる', () {
      expect(obd.handle([0x01, 0x0C, 0x0D, 0x05], engine), [
        0x41,
        0x0C,
        0x0C,
        0x80,
        0x0D,
        0x00,
        0x05,
        0x7D,
      ]);
      expect(obd.handle([0x01, 0x0C, 0xFF], engine), [0x41, 0x0C, 0x0C, 0x80]);
    });
    test('対応 PID がなければ null', () {
      expect(obd.handle([0x01, 0xFF], engine), isNull);
      expect(obd.handle([0x01], engine), isNull);
    });
  });

  group('Mode 03 / 07 / 0A', () {
    test('03 は確定 DTC、0 件は 43 00', () {
      expect(obd.handle([0x03], engine), [0x43, 0x00]);
      obd.addConfirmedDtc(engine, 'P0301');
      expect(obd.handle([0x03], engine), [0x43, 0x01, 0x03, 0x01]);
    });
    test('07 は保留、0A は永続', () {
      engine.pendingDtcs.add('P0171');
      engine.permanentDtcs.add('P0301');
      expect(obd.handle([0x07], engine), [0x47, 0x01, 0x01, 0x71]);
      expect(obd.handle([0x0A], engine), [0x4A, 0x01, 0x03, 0x01]);
    });
    test('3 件は 8 バイト（複数フレームになる長さ）', () {
      for (final c in ['P0301', 'P0302', 'P0420']) {
        obd.addConfirmedDtc(engine, c);
      }
      expect(obd.handle([0x03], engine)!.length, 8);
    });
  });

  group('Mode 04', () {
    test('確定・保留・フリーズフレームを消し、永続は残す', () {
      obd.addConfirmedDtc(engine, 'P0301');
      engine.pendingDtcs.add('P0171');
      engine.permanentDtcs.add('P0301');
      v
        ..distanceSinceClearKm = 12
        ..distanceWithMilKm = 5
        ..secondsSinceClear = 100
        ..secondsWithMil = 50
        ..warmupsSinceClear = 3;
      expect(obd.handle([0x04], engine), [0x44]);
      expect(engine.confirmedDtcs, isEmpty);
      expect(engine.pendingDtcs, isEmpty);
      expect(engine.permanentDtcs, ['P0301']);
      expect(engine.freezeFrame, isNull);
      expect(v.distanceSinceClearKm, 0);
      expect(v.distanceWithMilKm, 0);
      expect(v.secondsSinceClear, 0);
      expect(v.secondsWithMil, 0);
      expect(v.warmupsSinceClear, 0);
      expect(v.readinessIncomplete, readinessSupported);
    });
    test('トランスミッションの消去は車両の積算値に触れない', () {
      v.distanceSinceClearKm = 12;
      tcm.confirmedDtcs.add('P0700');
      expect(obd.handle([0x04], tcm), [0x44]);
      expect(tcm.confirmedDtcs, isEmpty);
      expect(v.distanceSinceClearKm, 12);
    });
  });

  group('Mode 02 フリーズフレーム', () {
    test('保存前は無応答', () {
      expect(obd.handle([0x02, 0x0C, 0x00], engine), isNull);
    });
    test('確定 DTC を追加した瞬間の値を返す', () {
      final at = DateTime(2026, 9, 23, 14, 2, 11);
      withClock(Clock.fixed(at), () {
        v.rpm = 2480;
        obd.addConfirmedDtc(engine, 'P0420');
      });
      v.rpm = 900;
      expect(engine.freezeFrame!.capturedAt, at);
      expect(obd.handle([0x02, 0x0C, 0x00], engine), [
        0x42,
        0x0C,
        0x00,
        0x26,
        0xC0,
      ]);
      expect(obd.handle([0x02, 0x02, 0x00], engine), [
        0x42,
        0x02,
        0x00,
        0x04,
        0x20,
      ]);
      expect(obd.handle([0x02, 0x00, 0x00], engine), [
        0x42,
        0x00,
        0x00,
        0x7E,
        0x3F,
        0xA0,
        0x13,
      ]);
    });
    test('2 件目の DTC では上書きしない', () {
      obd.addConfirmedDtc(engine, 'P0420');
      obd.addConfirmedDtc(engine, 'P0301');
      expect(engine.freezeFrame!.dtc, 'P0420');
    });
    test('フレーム番号 00 以外と形式違いは無応答', () {
      obd.addConfirmedDtc(engine, 'P0420');
      expect(obd.handle([0x02, 0x0C, 0x01], engine), isNull);
      expect(obd.handle([0x02, 0x0C], engine), isNull);
    });
  });

  test('addConfirmedDtc は形式違いで例外、重複は無視', () {
    expect(() => obd.addConfirmedDtc(engine, 'X1'), throwsArgumentError);
    obd.addConfirmedDtc(engine, 'P0301');
    obd.addConfirmedDtc(engine, 'P0301');
    expect(engine.confirmedDtcs, ['P0301']);
  });

  group('Mode 06', () {
    test('06 00 はサポート MID ビットマップ', () {
      expect(obd.handle([0x06, 0x00], engine), [
        0x46,
        0x00,
        0x80,
        0x00,
        0x00,
        0x01,
      ]);
    });
    test('06 A2 は 9 バイト × 2 テスト', () {
      final r = obd.handle([0x06, 0xA2], engine)!;
      expect(r[0], 0x46);
      expect(r.length, 1 + 9 * 2);
      expect(r.sublist(1, 10), [
        0xA2,
        0x0B,
        0x24,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x02,
      ]);
    });
    test('未対応 MID は無応答', () {
      expect(obd.handle([0x06, 0x02], engine), isNull);
    });
  });

  group('Mode 09', () {
    test('09 00 のビットマップ', () {
      expect(obd.handle([0x09, 0x00], engine), [
        0x49,
        0x00,
        0x54,
        0x40,
        0x00,
        0x00,
      ]);
      expect(obd.handle([0x09, 0x00], tcm), [
        0x49,
        0x00,
        0x14,
        0x40,
        0x00,
        0x00,
      ]);
    });
    test('09 02 VIN', () {
      expect(obd.handle([0x09, 0x02], engine), [
        0x49,
        0x02,
        0x01,
        ...'WAUZZZ8K9AA000000'.codeUnits,
      ]);
      expect(obd.handle([0x09, 0x02], tcm), isNull);
    });
    test('09 04 CALID は 16 バイト、09 0A ECU 名は 20 バイト（00 で詰める）', () {
      expect(obd.handle([0x09, 0x04], engine)!.length, 3 + 16);
      final name = obd.handle([0x09, 0x0A], engine)!;
      expect(name.length, 3 + 20);
      expect(name.sublist(3, 20), 'ECM-EngineControl'.codeUnits);
      expect(name.sublist(20), [0, 0, 0]);
    });
    test('09 06 CVN', () {
      expect(obd.handle([0x09, 0x06], engine), [
        0x49,
        0x06,
        0x01,
        0x1A,
        0x2B,
        0x3C,
        0x4D,
      ]);
    });
  });

  test('05 / 08 / 範囲外 SID は無応答', () {
    expect(obd.handle([0x05, 0x00], engine), isNull);
    expect(obd.handle([0x08, 0x00], engine), isNull);
    expect(obd.handle([0x22, 0xF1, 0x90], engine), isNull);
    expect(obd.handle([], engine), isNull);
  });
}
