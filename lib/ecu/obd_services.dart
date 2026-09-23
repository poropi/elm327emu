import 'package:clock/clock.dart';

import '../vehicle/vehicle_state.dart';
import 'dtc.dart';
import 'ecu_profile.dart';
import 'pid_table.dart';

/// Mode 06 のテスト 1 件。CAN 形式では MID TID 単位 値(2) 最小(2) 最大(2) の 9 バイト。
class _MonitorTest {
  const _MonitorTest(this.tid, this.unit, this.value, this.min, this.max);
  final int tid;
  final int unit;
  final int value;
  final int min;
  final int max;
}

/// 値は合格範囲内の固定値。TID・単位 ID の意味は SAE J1979 と照合していない。
const Map<int, List<_MonitorTest>> _mode06 = {
  0x01: [
    _MonitorTest(0x80, 0x0B, 0x0158, 0x0100, 0x0200),
    _MonitorTest(0x81, 0x0B, 0x0098, 0x0000, 0x00C8),
  ],
  0x21: [_MonitorTest(0x80, 0x24, 0x0012, 0x0000, 0x0040)],
  0xA2: [
    _MonitorTest(0x0B, 0x24, 0x0000, 0x0000, 0x0002),
    _MonitorTest(0x0C, 0x24, 0x0001, 0x0000, 0x0002),
  ],
};

List<int> _padAscii(String s, int length) {
  final bytes = s.codeUnits.take(length).toList();
  return [...bytes, ...List.filled(length - bytes.length, 0)];
}

/// OBD-II の標準サービス（Mode 01〜0A）。
class ObdServices {
  ObdServices(this.vehicle);
  final VehicleState vehicle;

  /// SID から始まる要求 → 応答ペイロード。応答しないときは null。
  List<int>? handle(List<int> request, EcuProfile ecu) {
    if (request.isEmpty) return null;
    switch (request[0]) {
      case 0x01:
        return _mode01(request, ecu);
      case 0x02:
        return _mode02(request, ecu);
      case 0x03:
        return request.length == 1 ? _dtcList(0x43, ecu.confirmedDtcs) : null;
      case 0x04:
        if (request.length != 1) return null;
        clearDtcs(ecu);
        return [0x44];
      case 0x06:
        return _mode06Response(request);
      case 0x07:
        return request.length == 1 ? _dtcList(0x47, ecu.pendingDtcs) : null;
      case 0x09:
        return _mode09(request, ecu);
      case 0x0A:
        return request.length == 1 ? _dtcList(0x4A, ecu.permanentDtcs) : null;
      default:
        return null;
    }
  }

  /// 確定 DTC を追加する。最初の 1 件のとき、その時点の Mode 01 の値をフリーズフレームとして保存する。
  void addConfirmedDtc(EcuProfile ecu, String code) {
    if (!isValidDtc(code)) {
      throw ArgumentError.value(code, 'code', 'DTC の形式ではない');
    }
    if (ecu.confirmedDtcs.contains(code)) return;
    ecu.confirmedDtcs.add(code);
    ecu.freezeFrame ??= FreezeFrame(
      dtc: code,
      capturedAt: clock.now(),
      pids: {
        for (final pid in ecu.mode01Pids)
          if (pid != 0x01 && pid != 0x41)
            pid: pidTable[pid]!.encode(vehicle, ecu),
      },
    );
  }

  /// Mode 04 と同じ消去。永続 DTC は残す。
  void clearDtcs(EcuProfile ecu) {
    ecu.confirmedDtcs.clear();
    ecu.pendingDtcs.clear();
    ecu.freezeFrame = null;
    if (ecu.name != 'engine') return;
    vehicle
      ..distanceSinceClearKm = 0
      ..distanceWithMilKm = 0
      ..secondsSinceClear = 0
      ..secondsWithMil = 0
      ..warmupsSinceClear = 0
      ..readinessIncomplete = readinessSupported;
  }

  List<int>? _mode01(List<int> request, EcuProfile ecu) {
    if (request.length < 2) return null;
    final out = <int>[0x41];
    for (final pid in request.sublist(1)) {
      final data = mode01Data(pid, vehicle, ecu);
      if (data != null) {
        out
          ..add(pid)
          ..addAll(data);
      }
    }
    return out.length == 1 ? null : out;
  }

  List<int>? _mode02(List<int> request, EcuProfile ecu) {
    if (request.length != 3 || request[2] != 0x00) return null;
    final ff = ecu.freezeFrame;
    if (ff == null) return null;
    final pid = request[1];
    final stored = {...ff.pids.keys, 0x02};
    List<int>? data;
    if (isBitmapPid(pid)) {
      data = bitmapAvailable(pid, stored) ? supportBitmap(pid, stored) : null;
    } else if (pid == 0x02) {
      data = dtcToBytes(ff.dtc);
    } else {
      data = ff.pids[pid];
    }
    return data == null ? null : [0x42, pid, 0x00, ...data];
  }

  List<int> _dtcList(int sid, List<String> codes) => [
    sid,
    codes.length,
    for (final c in codes) ...dtcToBytes(c),
  ];

  List<int>? _mode06Response(List<int> request) {
    if (request.length != 2) return null;
    final mid = request[1];
    final mids = _mode06.keys.toSet();
    if (isBitmapPid(mid)) {
      return bitmapAvailable(mid, mids)
          ? [0x46, mid, ...supportBitmap(mid, mids)]
          : null;
    }
    final tests = _mode06[mid];
    if (tests == null) return null;
    return [
      0x46,
      for (final t in tests) ...[
        mid, t.tid, t.unit, //
        t.value >> 8, t.value & 0xFF,
        t.min >> 8, t.min & 0xFF,
        t.max >> 8, t.max & 0xFF,
      ],
    ];
  }

  List<int>? _mode09(List<int> request, EcuProfile ecu) {
    if (request.length != 2) return null;
    final pid = request[1];
    final supported = ecu.mode09Pids;
    if (pid == 0x00) return [0x49, 0x00, ...supportBitmap(0, supported)];
    if (!supported.contains(pid)) return null;
    switch (pid) {
      case 0x02:
        return [0x49, 0x02, 0x01, ...ecu.vin.codeUnits];
      case 0x04:
        return [0x49, 0x04, 0x01, ..._padAscii(ecu.calid, 16)];
      case 0x06:
        return [0x49, 0x06, 0x01, ...ecu.cvn];
      case 0x0A:
        return [0x49, 0x0A, 0x01, ..._padAscii(ecu.ecuName, 20)];
      default:
        return null;
    }
  }
}
