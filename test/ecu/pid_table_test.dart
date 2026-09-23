import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/pid_table.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late VehicleState v;
  late EcuProfile engine;
  late EcuProfile tcm;
  setUp(() {
    v = VehicleState.defaults();
    engine = EcuProfile.engine();
    tcm = EcuProfile.transmission();
  });

  List<int>? d(int pid, [EcuProfile? e]) => mode01Data(pid, v, e ?? engine);

  test('全 PID に定義があり、空でないデータを返す', () {
    for (final pid in {...engineMode01Pids, 0xA4}) {
      expect(pidTable.containsKey(pid), isTrue, reason: hexPid(pid));
      final e = pid == 0xA4 ? tcm : engine;
      expect(pidTable[pid]!.encode(v, e), isNotEmpty, reason: hexPid(pid));
    }
  });

  group('エンコード（Wikipedia の式の逆）', () {
    test('0C 回転数', () {
      v.rpm = 1726;
      expect(d(0x0C), [0x1A, 0xF8]);
      v.rpm = 2150;
      expect(d(0x0C), [0x21, 0x98]);
    });
    test('05 水温 / 0F 吸気温 / 46 外気温 / 5C 油温 は +40', () {
      expect(d(0x05), [0x7D]); // 85 + 40
      v.intakeTempC = -40;
      expect(d(0x0F), [0x00]);
      v.ambientTempC = 22;
      expect(d(0x46), [0x3E]);
      v.oilTempC = 92;
      expect(d(0x5C), [0x84]);
    });
    test('04 負荷 / 11 スロットル / 2F 燃料 は ×255/100', () {
      v.engineLoadPct = 100;
      expect(d(0x04), [0xFF]);
      v.throttlePct = 50;
      expect(d(0x11), [0x80]);
      v.fuelLevelPct = 0;
      expect(d(0x2F), [0x00]);
    });
    test('06 燃料トリム: 1.6% → 0x82（130/1.28-100 = 1.56）', () {
      expect(d(0x06), [0x82]);
    });
    test('0E 点火時期: 12.5° → 0x99', () {
      v.timingDeg = 12.5;
      expect(d(0x0E), [0x99]);
    });
    test('10 MAF: 7.2 g/s → 0x02D0', () {
      v.maf = 7.2;
      expect(d(0x10), [0x02, 0xD0]);
    });
    test('1F 経過時間: 872 秒 → 0x0368', () {
      v.runTimeSec = 872;
      expect(d(0x1F), [0x03, 0x68]);
    });
    test('3C 触媒温度: 420°C → 0x11F8', () {
      expect(d(0x3C), [0x11, 0xF8]);
    });
    test('42 電圧: 12.4V → 0x3070', () {
      expect(d(0x42), [0x30, 0x70]);
    });
    test('44 λ: 1.0 → 0x8000', () {
      expect(d(0x44), [0x80, 0x00]);
    });
    test('5E 燃料消費率: 4.1 L/h → 0x0052', () {
      v.fuelRateLph = 4.1;
      expect(d(0x5E), [0x00, 0x52]);
    });
    test('A6 走行距離: 48213.4 km → 0x00075B56', () {
      expect(d(0xA6), [0x00, 0x07, 0x5B, 0x56]);
    });
    test('4D / 4E は分', () {
      v.secondsWithMil = 125;
      v.secondsSinceClear = 3600;
      expect(d(0x4D), [0x00, 0x02]);
      expect(d(0x4E), [0x00, 0x3C]);
    });
    test('値は範囲外でも飽和する', () {
      v.speedKmh = 400;
      expect(d(0x0D), [0xFF]);
      v.rpm = -5;
      expect(d(0x0C), [0x00, 0x00]);
    });
  });

  group('0101 モニタ状態', () {
    test('確定 DTC 1 件なら MIL 点灯・件数 1、レディネスは完了', () {
      engine.confirmedDtcs.add('P0301');
      expect(d(0x01), [0x81, 0x07, 0x65, 0x00]);
    });
    test('DTC なしなら A = 0、消去直後は D = C（全未完了）', () {
      v.readinessIncomplete = readinessSupported;
      expect(d(0x01), [0x00, 0x07, 0x65, 0x65]);
    });
    test('0141 の A は常に 0', () {
      engine.confirmedDtcs.add('P0301');
      expect(d(0x41)![0], 0x00);
    });
    test('トランスミッションは件数のみ', () {
      tcm.confirmedDtcs.addAll(['P0700', 'P0715']);
      expect(d(0x01, tcm), [0x82, 0x00, 0x00, 0x00]);
    });
  });

  test('A4 ギア: 62 km/h は 4 速・変速比 1.000', () {
    v.speedKmh = 62;
    expect(gearFor(62), 4);
    expect(d(0xA4, tcm), [0x02, 0x00, 0x03, 0xE8]);
    expect(gearFor(0), 1);
    expect(gearFor(120), 6);
  });

  group('ビットマップ（Python で計算した値と一致）', () {
    test('エンジン', () {
      expect(d(0x00), [0xBE, 0x3F, 0xA0, 0x13]);
      expect(d(0x20), [0x80, 0x03, 0xA0, 0x11]);
      expect(d(0x40), [0xFE, 0xDC, 0x80, 0x15]);
      expect(d(0x60), [0x00, 0x00, 0x00, 0x01]);
      expect(d(0x80), [0x00, 0x00, 0x00, 0x01]);
      expect(d(0xA0), [0x04, 0x00, 0x00, 0x00]);
      expect(d(0xC0), isNull);
    });
    test('トランスミッション', () {
      expect(d(0x00, tcm), [0x80, 0x00, 0x00, 0x01]);
      expect(d(0xA0, tcm), [0x10, 0x00, 0x00, 0x00]);
    });
  });

  test('未対応 PID は null', () {
    expect(d(0xFF), isNull);
    expect(d(0x0C, tcm), isNull);
    expect(d(0xA4), isNull);
  });
}

String hexPid(int pid) => pid.toRadixString(16);
