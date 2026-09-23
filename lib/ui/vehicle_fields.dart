import '../vehicle/vehicle_state.dart';

/// 車両タブ「その他の PID」の 1 行。
class VehicleField {
  const VehicleField(this.pid, this.label, this.unit, this.get, this.set, {this.digits = 0});

  final String pid;
  final String label;
  final String unit;
  final double Function(VehicleState v) get;
  final void Function(VehicleState v, double x) set;
  final int digits;

  String format(VehicleState v) => get(v).toStringAsFixed(digits);
}

/// 先頭 12 項目が最初に見える。残りは「すべて表示」で出す。
final List<VehicleField> vehicleFields = [
  VehicleField('0B', '吸気管圧力', 'kPa', (v) => v.mapKpa, (v, x) => v.mapKpa = x),
  VehicleField('0E', '点火時期', '°', (v) => v.timingDeg, (v, x) => v.timingDeg = x, digits: 1),
  VehicleField('0F', '吸気温', '°C', (v) => v.intakeTempC, (v, x) => v.intakeTempC = x),
  VehicleField('10', '空気流量 MAF', 'g/s', (v) => v.maf, (v, x) => v.maf = x, digits: 2),
  VehicleField('06', '短期燃料トリム', '%', (v) => v.stftPct, (v, x) => v.stftPct = x, digits: 1),
  VehicleField('07', '長期燃料トリム', '%', (v) => v.ltftPct, (v, x) => v.ltftPct = x, digits: 1),
  VehicleField('2F', '燃料残量', '%', (v) => v.fuelLevelPct, (v, x) => v.fuelLevelPct = x, digits: 1),
  VehicleField('33', '大気圧', 'kPa', (v) => v.baroKpa, (v, x) => v.baroKpa = x),
  VehicleField('46', '外気温', '°C', (v) => v.ambientTempC, (v, x) => v.ambientTempC = x),
  VehicleField('5C', '油温', '°C', (v) => v.oilTempC, (v, x) => v.oilTempC = x),
  VehicleField('5E', '燃料消費率', 'L/h', (v) => v.fuelRateLph, (v, x) => v.fuelRateLph = x, digits: 1),
  VehicleField('A6', '走行距離計', 'km', (v) => v.odometerKm, (v, x) => v.odometerKm = x, digits: 1),
  VehicleField('1F', '始動後の経過時間', 's', (v) => v.runTimeSec, (v, x) => v.runTimeSec = x),
  VehicleField('21', 'MIL 点灯後の距離', 'km', (v) => v.distanceWithMilKm, (v, x) => v.distanceWithMilKm = x),
  VehicleField('30', '消去後のウォームアップ', '回', (v) => v.warmupsSinceClear.toDouble(),
      (v, x) => v.warmupsSinceClear = x.round()),
  VehicleField('31', '消去後の距離', 'km', (v) => v.distanceSinceClearKm, (v, x) => v.distanceSinceClearKm = x),
  VehicleField('3C', '触媒温度', '°C', (v) => v.catalystTempC, (v, x) => v.catalystTempC = x),
  VehicleField('43', '絶対負荷', '%', (v) => v.absLoadPct, (v, x) => v.absLoadPct = x),
  VehicleField('44', '指令空燃比 λ', '', (v) => v.lambda, (v, x) => v.lambda = x, digits: 3),
  VehicleField('49', 'アクセル開度', '%', (v) => v.acceleratorPct, (v, x) => v.acceleratorPct = x),
  VehicleField('4D', 'MIL 点灯時間', 'min', (v) => v.secondsWithMil / 60, (v, x) => v.secondsWithMil = x * 60),
  VehicleField('4E', '消去後の時間', 'min', (v) => v.secondsSinceClear / 60, (v, x) => v.secondsSinceClear = x * 60),
];
