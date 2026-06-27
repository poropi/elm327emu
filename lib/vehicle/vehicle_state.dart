/// エミュレートする車両の現在状態。Simulator または UI が更新する。
class VehicleState {
  int rpm;
  double speedKmh;
  double coolantTempC;
  double engineLoadPct;
  double throttlePct;
  double intakeTempC;
  double maf; // g/s
  double fuelLevelPct;
  double batteryVoltage;
  List<String> dtcs;
  String vin;

  VehicleState({
    required this.rpm,
    required this.speedKmh,
    required this.coolantTempC,
    required this.engineLoadPct,
    required this.throttlePct,
    required this.intakeTempC,
    required this.maf,
    required this.fuelLevelPct,
    required this.batteryVoltage,
    required this.dtcs,
    required this.vin,
  });

  factory VehicleState.defaults() => VehicleState(
        rpm: 800,
        speedKmh: 0,
        coolantTempC: 85,
        engineLoadPct: 20,
        throttlePct: 12,
        intakeTempC: 30,
        maf: 3.5,
        fuelLevelPct: 70,
        batteryVoltage: 12.4,
        dtcs: ['P0301'],
        vin: 'WAUZZZ8K9AA000000',
      );
}
