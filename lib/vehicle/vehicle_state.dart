/// エミュレートする車両の現在状態。Simulator または UI が更新する。
class VehicleState {
  int rpm = 800;
  double speedKmh = 0;
  double coolantTempC = 85;
  double engineLoadPct = 20;
  double throttlePct = 12;
  double intakeTempC = 30;
  double maf = 3.5; // g/s
  double fuelLevelPct = 70;
  double batteryVoltage = 12.4;
  double stftPct = 1.6; // 短期燃料トリム B1
  double ltftPct = -0.8; // 長期燃料トリム B1
  double mapKpa = 33; // 吸気管圧力
  double timingDeg = 10; // 点火時期
  double baroKpa = 101;
  double ambientTempC = 22;
  double oilTempC = 90;
  double fuelRateLph = 0.8;
  double catalystTempC = 420;
  double lambda = 1.0;
  double acceleratorPct = 10;
  double absLoadPct = 18;
  double runTimeSec = 0; // エンジン始動後の経過時間
  double odometerKm = 48213.4;
  double distanceSinceClearKm = 0;
  double distanceWithMilKm = 0;
  double secondsSinceClear = 0;
  double secondsWithMil = 0;
  int warmupsSinceClear = 0;

  /// レディネスの未完了ビット（0101 の D バイト。ビットの意味は C バイトと同じ）。
  int readinessIncomplete = 0;

  // 旧エンジン（Elm327Engine）用。Task 13 で削除する。
  List<String> dtcs = ['P0301'];
  String vin = 'WAUZZZ8K9AA000000';

  VehicleState();

  factory VehicleState.defaults() => VehicleState();
}
