import 'dart:math';

import '../ecu/ecu_profile.dart';

/// ELM327 がエラーとして出す文言（データシート p.78–80）。
enum ElmErrorKind {
  canError('CAN ERROR'),
  busError('BUS ERROR'),
  busBusy('BUS BUSY'),
  bufferFull('BUFFER FULL'),
  dataError('DATA ERROR'),
  dataErrorMark('<DATA ERROR'),
  rxErrorMark('<RX ERROR'),
  fbError('FB ERROR'),
  err94('ERR94'),
  lvReset('LV RESET'),
  actAlert('ACT ALERT');

  const ElmErrorKind(this.text);
  final String text;

  /// 最後のデータ行の横に付ける種類。
  bool get isMark => this == dataErrorMark || this == rxErrorMark;

  /// 実機と同じく AT 設定を初期値に戻す種類。
  bool get resetsState => this == err94 || this == lvReset;
}

enum ErrorTrigger { once, always }

/// UI や CLI から変更する障害の設定。
class FaultConfig {
  bool ignitionOff = false;
  final Set<String> silentEcus = {};
  int delayMs = 0;
  int dropPercent = 0;
  bool responsePending = false;
  bool truncateMultiFrame = false;
  ElmErrorKind? error;
  ErrorTrigger errorTrigger = ErrorTrigger.once;
  bool errorArmed = false;
}

/// 障害の判定。ECU と ELM セッションが参照する。
class FaultInjector {
  FaultInjector(this.config, {Random? random}) : _random = random ?? Random();

  final FaultConfig config;
  final Random _random;

  bool isSilent(EcuProfile ecu) =>
      config.ignitionOff || config.silentEcus.contains(ecu.name);

  Duration get extraDelay => Duration(milliseconds: config.delayMs);

  /// この要求の応答をすべて捨てるか。
  bool rollDrop() =>
      config.dropPercent > 0 && _random.nextInt(100) < config.dropPercent;

  /// 発火しているエラーを取り出す。once なら取り出した時点で解除する。
  ElmErrorKind? takeError() {
    final kind = config.error;
    if (kind == null || !config.errorArmed) return null;
    if (config.errorTrigger == ErrorTrigger.once) config.errorArmed = false;
    return kind;
  }
}
