import '../vehicle/vehicle_state.dart';
import 'ecu_profile.dart';

/// Mode 01 の PID 定義。式は Wikipedia「OBD-II PIDs」の Service 01 表の逆。
typedef PidEncoder = List<int> Function(VehicleState v, EcuProfile ecu);

class PidDef {
  const PidDef(this.pid, this.label, this.encode);
  final int pid;
  final String label;
  final PidEncoder encode;
}

int _clamp(num v, int lo, int hi) => v.round().clamp(lo, hi).toInt();

int pct255(double pct) => _clamp(pct.clamp(0, 100) * 255 / 100, 0, 255);
int temp40(double c) => _clamp(c + 40, 0, 255);
int _trim(double pct) => _clamp((pct + 100) * 128 / 100, 0, 255);
List<int> _u8(num v) => [_clamp(v, 0, 255)];
List<int> _u16(num v) {
  final x = _clamp(v, 0, 0xFFFF);
  return [x >> 8, x & 0xFF];
}

List<int> _u32(num v) {
  final x = _clamp(v, 0, 0xFFFFFFFF);
  return [(x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF];
}

/// 0101 の C バイト（対応している火花点火車のテスト）: 触媒・EVAP・O2・O2 ヒーター。
const readinessSupported = 0x65;

List<int> _monitorStatus(VehicleState v, EcuProfile e, {required bool sinceClear}) {
  final count = e.confirmedDtcs.length.clamp(0, 0x7F).toInt();
  final a = sinceClear ? ((e.confirmedDtcs.isEmpty ? 0 : 0x80) | count) : 0x00;
  if (e.name != 'engine') return [a, 0x00, 0x00, 0x00];
  // B: 共通テスト（ミスファイア・燃料系・コンポーネント）が対応済みかつ完了、火花点火。
  return [a, 0x07, readinessSupported, v.readinessIncomplete & readinessSupported];
}

const _gearRatios = [3.5, 2.1, 1.4, 1.0, 0.8, 0.65];

int gearFor(double speedKmh) {
  if (speedKmh < 20) return 1;
  if (speedKmh < 40) return 2;
  if (speedKmh < 60) return 3;
  if (speedKmh < 80) return 4;
  if (speedKmh < 100) return 5;
  return 6;
}

double gearRatioFor(double speedKmh) => _gearRatios[gearFor(speedKmh) - 1];

final List<PidDef> _defs = [
  PidDef(0x01, 'モニタ状態', (v, e) => _monitorStatus(v, e, sinceClear: true)),
  PidDef(0x03, '燃料系の状態', (v, e) => [0x02, 0x00]),
  PidDef(0x04, 'エンジン負荷', (v, e) => [pct255(v.engineLoadPct)]),
  PidDef(0x05, '水温', (v, e) => [temp40(v.coolantTempC)]),
  PidDef(0x06, '短期燃料トリム B1', (v, e) => [_trim(v.stftPct)]),
  PidDef(0x07, '長期燃料トリム B1', (v, e) => [_trim(v.ltftPct)]),
  PidDef(0x0B, '吸気管圧力', (v, e) => _u8(v.mapKpa)),
  PidDef(0x0C, '回転数', (v, e) => _u16(v.rpm * 4)),
  PidDef(0x0D, '車速', (v, e) => _u8(v.speedKmh)),
  PidDef(0x0E, '点火時期', (v, e) => _u8((v.timingDeg + 64) * 2)),
  PidDef(0x0F, '吸気温', (v, e) => [temp40(v.intakeTempC)]),
  PidDef(0x10, '空気流量 MAF', (v, e) => _u16(v.maf * 100)),
  PidDef(0x11, 'スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x13, 'O2 センサの有無', (v, e) => [0x03]),
  PidDef(0x1C, 'OBD 規格', (v, e) => [0x06]),
  PidDef(0x1F, '始動後の経過時間', (v, e) => _u16(v.runTimeSec)),
  PidDef(0x21, 'MIL 点灯後の距離', (v, e) => _u16(v.distanceWithMilKm)),
  PidDef(0x2F, '燃料残量', (v, e) => [pct255(v.fuelLevelPct)]),
  PidDef(0x30, '消去後のウォームアップ回数', (v, e) => _u8(v.warmupsSinceClear)),
  PidDef(0x31, '消去後の距離', (v, e) => _u16(v.distanceSinceClearKm)),
  PidDef(0x33, '大気圧', (v, e) => _u8(v.baroKpa)),
  PidDef(0x3C, '触媒温度 B1S1', (v, e) => _u16((v.catalystTempC + 40) * 10)),
  PidDef(0x41, '今回サイクルのモニタ状態', (v, e) => _monitorStatus(v, e, sinceClear: false)),
  PidDef(0x42, '制御モジュール電圧', (v, e) => _u16(v.batteryVoltage * 1000)),
  PidDef(0x43, '絶対負荷', (v, e) => _u16(v.absLoadPct * 255 / 100)),
  PidDef(0x44, '指令空燃比', (v, e) => _u16(v.lambda * 32768)),
  PidDef(0x45, '相対スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x46, '外気温', (v, e) => [temp40(v.ambientTempC)]),
  PidDef(0x47, '絶対スロットル B', (v, e) => [pct255(v.throttlePct * 0.9 + 8)]),
  PidDef(0x49, 'アクセル開度 D', (v, e) => [pct255(v.acceleratorPct)]),
  PidDef(0x4A, 'アクセル開度 E', (v, e) => [pct255(v.acceleratorPct * 0.5)]),
  PidDef(0x4C, '指令スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x4D, 'MIL 点灯時間', (v, e) => _u16(v.secondsWithMil / 60)),
  PidDef(0x4E, '消去後の時間', (v, e) => _u16(v.secondsSinceClear / 60)),
  PidDef(0x51, '燃料の種類', (v, e) => [0x01]),
  PidDef(0x5C, '油温', (v, e) => [temp40(v.oilTempC)]),
  PidDef(0x5E, '燃料消費率', (v, e) => _u16(v.fuelRateLph * 20)),
  PidDef(0xA4, '実ギア', (v, e) => [0x02, 0x00, ..._u16(gearRatioFor(v.speedKmh) * 1000)]),
  PidDef(0xA6, '走行距離計', (v, e) => _u32(v.odometerKm * 10)),
];

final Map<int, PidDef> pidTable = {for (final d in _defs) d.pid: d};

bool isBitmapPid(int pid) => pid % 0x20 == 0;

/// ビットマップ PID [base] に ECU が応答するか（base 0 は常に、ほかは base より上の PID があるとき）。
bool bitmapAvailable(int base, Set<int> supported) =>
    base == 0 || supported.any((p) => p > base);

/// [base]+1〜[base]+0x20 のサポートビットマップ 4 バイト。末尾ビットは次の範囲に PID があれば立つ。
List<int> supportBitmap(int base, Set<int> supported) {
  final out = [0, 0, 0, 0];
  for (var i = 0; i < 32; i++) {
    final pid = base + 1 + i;
    final on = supported.contains(pid) ||
        (pid == base + 0x20 && supported.any((p) => p > base + 0x20));
    if (on) out[i ~/ 8] |= 0x80 >> (i % 8);
  }
  return out;
}

/// ECU が Mode 01 の [pid] に返すデータ（PID を含まない）。未対応は null。
List<int>? mode01Data(int pid, VehicleState v, EcuProfile ecu) {
  if (isBitmapPid(pid)) {
    return bitmapAvailable(pid, ecu.mode01Pids)
        ? supportBitmap(pid, ecu.mode01Pids)
        : null;
  }
  if (!ecu.mode01Pids.contains(pid)) return null;
  return pidTable[pid]!.encode(v, ecu);
}
