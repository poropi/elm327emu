import '../can/can_frame.dart';

enum AdaptiveTiming { off, auto1, auto2 }

/// プロトコル番号 → 名前（ATDP の表示。データシート p.24）。
const Map<int, String> protocolNames = {
  0x1: 'SAE J1850 PWM',
  0x2: 'SAE J1850 VPW',
  0x3: 'ISO 9141-2',
  0x4: 'ISO 14230-4 (KWP 5BAUD)',
  0x5: 'ISO 14230-4 (KWP FAST)',
  0x6: 'ISO 15765-4 (CAN 11/500)',
  0x7: 'ISO 15765-4 (CAN 29/500)',
  0x8: 'ISO 15765-4 (CAN 11/250)',
  0x9: 'ISO 15765-4 (CAN 29/250)',
  0xA: 'SAE J1939 (CAN 29/250)',
  0xB: 'USER1 CAN (11* /125)',
  0xC: 'USER2 CAN (11* /50)',
};

/// ELM327 の設定と実行時の状態（1 接続ぶん）。
class ElmState {
  ElmState() {
    defaults();
  }

  // ---- AT D / AT Z で初期値に戻るもの ----
  late bool echo, linefeed, spaces, headers, dlc, caf, responses;
  late bool allowLong, variableDlc, autoFlowControl;
  late int protocol;
  late bool autoSearch;
  int? established;
  int? header; // SH で設定した値（11bit はその下位 11bit、29bit は下位 3 バイト）
  late int priority29, testerAddress;
  int? receiveAddress, craId, filterId, maskId, extendedAddress;
  late int timeoutHex;
  late AdaptiveTiming timing;
  late int flowMode;
  int? flowHeader;
  List<int>? flowData;
  /// PB xx yy（プロトコル B のオプションとボーレート）。受け付けて保持するだけ。
  List<int>? protocolB;

  // ---- 電源を切っても残るもの（EEPROM 相当） ----
  int storedProtocol = 0;
  bool storedAuto = true;
  String? deviceId;
  int storedByte = 0;
  final Map<int, int> ppValues = {};
  final Set<int> ppEnabled = {};
  bool memory = true;
  int activityTimeout = 0;
  double? voltageOffset;

  // ---- 実行時 ----
  String? lastCommand;
  CanFrame? lastFrame;
  DateTime? lastActivity;
  int txErrors = 0;
  int rxErrors = 0;

  /// AT D。保存したプロトコルを読み戻し、ヘッダ・フィルタ・タイマーを初期値にする（p.13）。
  void defaults() {
    echo = true;
    linefeed = false;
    spaces = true;
    headers = false;
    dlc = false;
    caf = true;
    responses = true;
    allowLong = false;
    variableDlc = false;
    autoFlowControl = true;
    protocol = storedProtocol;
    autoSearch = storedAuto;
    established = null;
    header = null;
    priority29 = 0x18;
    testerAddress = 0xF1;
    receiveAddress = null;
    craId = null;
    filterId = null;
    maskId = null;
    extendedAddress = null;
    timeoutHex = 0x32;
    timing = AdaptiveTiming.auto1;
    flowMode = 0;
    flowHeader = null;
    flowData = null;
    protocolB = null;
  }

  /// AT Z / AT WS。電源を入れ直したのと同じ。
  void reset() {
    defaults();
    lastCommand = null;
    lastFrame = null;
    txErrors = 0;
    rxErrors = 0;
  }

  /// SP / TP。[save] は SP h・SP Ah・SP 00 のとき true（SP 0 と TP は保存しない）。
  void setProtocol(int p, {required bool auto, required bool save}) {
    protocol = p;
    autoSearch = auto || p == 0;
    established = null;
    if (save) {
      storedProtocol = p;
      storedAuto = autoSearch;
    }
  }

  static bool isCanProtocol(int p) => p >= 6 && p <= 9;

  /// 送信に使うプロトコル。自動で CAN 以外から始めた場合も CAN 6 で探す。
  int get activeProtocol {
    final e = established;
    if (e != null) return e;
    if (isCanProtocol(protocol)) return protocol;
    return autoSearch ? 6 : protocol;
  }

  bool get is29bit => activeProtocol == 7 || activeProtocol == 9;

  String describeProtocol() {
    final n = established ?? protocol;
    if (autoSearch) return n == 0 ? 'AUTO' : 'AUTO, ${protocolNames[n]}';
    return protocolNames[n] ?? 'AUTO';
  }

  String describeProtocolNumber() {
    final n = (established ?? protocol).toRadixString(16).toUpperCase();
    return autoSearch ? 'A$n' : n;
  }

  Duration get timeout =>
      Duration(milliseconds: (timeoutHex == 0 ? 0x32 : timeoutHex) * 4);

  int get txId {
    final h = header;
    if (is29bit) {
      final low = h ?? (0xDB3300 | testerAddress);
      return ((priority29 & 0x1F) << 24) | (low & 0xFFFFFF);
    }
    return h == null ? 0x7DF : h & 0x7FF;
  }

  /// 要求への応答として受け取るフレームか。
  bool acceptsResponse(CanFrame f) {
    if (f.extended != is29bit) return false;
    final user = _userFilter(f);
    if (user != null) return user;
    if (is29bit) return (f.id & 0x00FFFF00) == (0x00DA0000 | (testerAddress << 8));
    return f.id >= 0x7E8 && f.id <= 0x7EF;
  }

  /// 監視（ATMA / MR / MT）で表示するフレームか。既定の 7E8〜7EF フィルタは使わない。
  bool acceptsMonitor(CanFrame f, {int? receiver, int? transmitter}) {
    if (f.extended != is29bit) return false;
    if (_userFilter(f) == false) return false;
    if (receiver != null) {
      final r = f.extended ? (f.id >> 8) & 0xFF : (f.id >> 8) & 0x07;
      if (r != receiver) return false;
    }
    if (transmitter != null && (f.id & 0xFF) != transmitter) return false;
    return true;
  }

  bool? _userFilter(CanFrame f) {
    final cra = craId;
    if (cra != null) return f.id == cra;
    final mask = maskId;
    if (mask != null) return (f.id & mask) == ((filterId ?? 0) & mask);
    final ra = receiveAddress;
    if (ra != null) {
      return f.extended ? ((f.id >> 8) & 0xFF) == ra : (f.id & 0xFF) == ra;
    }
    return null;
  }
}
