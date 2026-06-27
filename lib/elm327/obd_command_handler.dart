import 'elm_state.dart';
import 'obd_encoding.dart';
import '../vehicle/vehicle_state.dart';

/// OBD-II モードコマンドを処理する。
class ObdCommandHandler {
  ObdCommandHandler(this.state, this.vehicle);
  final ElmState state;
  final VehicleState vehicle;

  List<String> handle(String cmd) {
    final c = cmd.toUpperCase().replaceAll(' ', '');
    final searching = <String>[];
    if (!state.initialized) {
      state.initialized = true;
      searching.add('SEARCHING...');
    }

    final data = _dataBytes(c);
    if (data == null) return ['NO DATA'];

    final lines = <String>[];
    if (data.length > 7) {
      // マルチフレーム（VIN 等）。headers off 前提の ELM 表示。
      lines.addAll(isoTpMultiline(data));
    } else if (state.headers) {
      // 7E8 + PCI(データ長) + データ
      final pci = toHex2(data.length);
      lines.add('7E8 $pci ${formatBytes(data, spaces: state.spaces)}'.trimRight() +
          (state.spaces ? ' ' : ''));
    } else {
      lines.add(formatBytes(data, spaces: state.spaces));
    }
    return [...searching, ...lines];
  }

  /// 応答データバイト（サービス応答バイト＋PID＋値）を返す。未対応は null。
  List<int>? _dataBytes(String c) {
    if (c.length < 2) return null;
    final mode = c.substring(0, 2);
    switch (mode) {
      case '01':
        return _mode01(c.substring(2));
      case '03':
        return _mode03();
      case '04':
        vehicle.dtcs = [];
        return [0x44];
      case '07':
      case '0A':
        return [int.parse(mode, radix: 16) + 0x40, 0x00];
      case '09':
        return _mode09(c.substring(2));
      case '02':
        return _mode02(c.substring(2));
      case '06':
        return [0x46, 0x00];
      default:
        return null;
    }
  }

  List<int>? _mode01(String pidHex) {
    final pid = int.tryParse(pidHex, radix: 16);
    if (pid == null) return null;
    switch (pid) {
      case 0x00:
        // 0x01..0x20 のサポートビットマップ（実装PIDを反映）
        return [0x41, 0x00, 0x18, 0x3B, 0x80, 0x11];
      case 0x04: // エンジン負荷
        return [0x41, 0x04, _pct255(vehicle.engineLoadPct)];
      case 0x05: // 水温
        return [0x41, 0x05, (vehicle.coolantTempC + 40).round() & 0xFF];
      case 0x0C: // RPM
        return [0x41, 0x0C, rpmA(vehicle.rpm), rpmB(vehicle.rpm)];
      case 0x0D: // 車速
        return [0x41, 0x0D, vehicle.speedKmh.round() & 0xFF];
      case 0x0F: // 吸気温
        return [0x41, 0x0F, (vehicle.intakeTempC + 40).round() & 0xFF];
      case 0x10: // MAF
        final m = (vehicle.maf * 100).round();
        return [0x41, 0x10, (m >> 8) & 0xFF, m & 0xFF];
      case 0x11: // スロットル
        return [0x41, 0x11, _pct255(vehicle.throttlePct)];
      case 0x20:
        return [0x41, 0x20, 0x00, 0x00, 0x00, 0x01];
      case 0x2F: // 燃料レベル
        return [0x41, 0x2F, _pct255(vehicle.fuelLevelPct)];
      case 0x40:
        return [0x41, 0x40, 0x40, 0x00, 0x00, 0x00];
      case 0x42: // 制御モジュール電圧
        final mv = (vehicle.batteryVoltage * 1000).round();
        return [0x41, 0x42, (mv >> 8) & 0xFF, mv & 0xFF];
      default:
        return null;
    }
  }

  int _pct255(double pct) => (pct * 255 / 100).round() & 0xFF;

  List<int> _mode03() {
    final bytes = <int>[0x43, vehicle.dtcs.length];
    for (final dtc in vehicle.dtcs) {
      bytes.addAll(dtcToBytes(dtc));
    }
    return bytes;
  }

  List<int>? _mode09(String pidHex) {
    final pid = int.tryParse(pidHex, radix: 16);
    if (pid == 0x02) {
      // 49 02 01 + VIN(17 ASCII)
      return [0x49, 0x02, 0x01, ...vehicle.vin.codeUnits];
    }
    if (pid == 0x00) {
      return [0x49, 0x00, 0x00, 0x00, 0x00, 0x04];
    }
    return null;
  }

  List<int>? _mode02(String rest) {
    // フリーズフレーム: 0202xx を簡略再現（RPM のフレーム）
    if (rest.startsWith('02')) {
      return [0x42, 0x02, rpmA(vehicle.rpm), rpmB(vehicle.rpm)];
    }
    return [0x42, 0x00, 0x00, 0x00, 0x00, 0x00];
  }
}
