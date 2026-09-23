import '../util/hex.dart';

/// 全 ECU 宛て（functional）の要求 ID。
const functionalId11 = 0x7DF;
const functionalId29 = 0x18DB33F1;

/// エンジン ECU が対応する Mode 01 の PID（ビットマップ PID を除く 38 個）。
const Set<int> engineMode01Pids = {
  0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, //
  0x0F, 0x10, 0x11, 0x13, 0x1C, 0x1F, 0x21, 0x2F, 0x30, 0x31,
  0x33, 0x3C, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49,
  0x4A, 0x4C, 0x4D, 0x4E, 0x51, 0x5C, 0x5E, 0xA6,
};

/// Mode 22 の DID の値。ASCII か 16 進のバイト列。
class DidValue {
  DidValue.ascii(String text)
    : isAscii = true,
      bytes = List.unmodifiable(text.codeUnits) {
    if (text.isEmpty || text.codeUnits.any((c) => c < 0x20 || c > 0x7E)) {
      throw ArgumentError.value(text, 'text', '表示可能な ASCII 1 文字以上');
    }
  }

  DidValue.hex(List<int> bytes)
    : isAscii = false,
      bytes = List.unmodifiable(bytes) {
    if (bytes.isEmpty || bytes.any((b) => b < 0 || b > 0xFF)) {
      throw ArgumentError.value(bytes, 'bytes', '1 バイト以上');
    }
  }

  final bool isAscii;
  final List<int> bytes;

  String get display =>
      isAscii ? String.fromCharCodes(bytes) : bytes.map(hex2).join(' ');
}

/// フリーズフレーム。確定 DTC を追加した時点の Mode 01 の値（PID → データバイト）。
class FreezeFrame {
  FreezeFrame({
    required this.dtc,
    required Map<int, List<int>> pids,
    required this.capturedAt,
  }) : pids = Map.unmodifiable(pids);

  final String dtc;
  final Map<int, List<int>> pids;
  final DateTime capturedAt;
}

/// ECU 1 台ぶんの設定と状態。
class EcuProfile {
  EcuProfile({
    required this.name,
    required this.label,
    required this.requestId11,
    required this.address29,
    required this.enabled,
    required this.baseLatency,
    required Set<int> mode01Pids,
    required this.vin,
    required this.calid,
    required this.cvn,
    required this.ecuName,
    required Map<int, DidValue> dids,
  }) : mode01Pids = Set.unmodifiable(mode01Pids),
       dids = Map.of(dids);

  factory EcuProfile.engine() => EcuProfile(
    name: 'engine',
    label: 'エンジン',
    requestId11: 0x7E0,
    address29: 0x10,
    enabled: true,
    baseLatency: const Duration(milliseconds: 8),
    mode01Pids: engineMode01Pids,
    vin: 'WAUZZZ8K9AA000000',
    calid: '8K0907115B  0010',
    cvn: [0x1A, 0x2B, 0x3C, 0x4D],
    ecuName: 'ECM-EngineControl',
    dids: {
      0xF190: DidValue.ascii('WAUZZZ8K9AA000000'),
      0xF187: DidValue.ascii('8K0907115B'),
      0xF18C: DidValue.ascii('SN00123456'),
      0xF191: DidValue.hex([0x0A, 0x1B, 0x2C, 0x3D]),
    },
  );

  factory EcuProfile.transmission() => EcuProfile(
    name: 'transmission',
    label: 'トランスミッション',
    requestId11: 0x7E1,
    address29: 0x18,
    enabled: false,
    baseLatency: const Duration(milliseconds: 15),
    mode01Pids: {0x01, 0xA4},
    vin: '',
    calid: 'TCM0AW300000001',
    cvn: [0x5E, 0x6F, 0x70, 0x81],
    ecuName: 'TCM-TransmissionCtl',
    dids: {
      0xF187: DidValue.ascii('0AW300'),
      0xF18C: DidValue.ascii('SN00987654'),
    },
  );

  final String name;
  final String label;
  final int requestId11;
  final int address29;
  bool enabled;
  final Duration baseLatency;
  final Set<int> mode01Pids;
  final List<String> confirmedDtcs = [];
  final List<String> pendingDtcs = [];
  final List<String> permanentDtcs = [];
  FreezeFrame? freezeFrame;
  String vin;
  String calid;
  List<int> cvn;
  String ecuName;
  final Map<int, DidValue> dids;

  int get responseId11 => requestId11 + 8;

  /// テスター F1 からの物理アドレス要求 ID（18 DA &lt;ECU&gt; F1）。
  int get requestId29 => 0x18DA0000 | (address29 << 8) | 0xF1;

  /// テスター [tester] 宛ての応答 ID（18 DA &lt;tester&gt; &lt;ECU&gt;）。
  int responseId29For(int tester) =>
      0x18DA0000 | ((tester & 0xFF) << 8) | address29;

  Set<int> get mode09Pids => {if (vin.isNotEmpty) 0x02, 0x04, 0x06, 0x0A};
}
