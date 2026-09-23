import 'dart:math' as math;

import 'package:clock/clock.dart';

import '../util/hex.dart';
import 'elm_state.dart';

const elmId = 'ELM327 v1.5';
const elmDescription = 'OBDII to RS232 Interpreter';

/// AT コマンドの結果。
sealed class AtOutcome {
  const AtOutcome();
}

class AtReply extends AtOutcome {
  const AtReply(this.lines);
  final List<String> lines;
}

/// Z / WS。セッションが空行 2 つと ID を出す。
class AtReset extends AtOutcome {
  const AtReset();
}

class AtLowPower extends AtOutcome {
  const AtLowPower();
}

class AtMonitor extends AtOutcome {
  const AtMonitor({this.receiver, this.transmitter});
  final int? receiver;
  final int? transmitter;
}

class AtRtr extends AtOutcome {
  const AtRtr();
}

class _Rule {
  _Rule(String pattern, this.run) : pattern = RegExp('^$pattern\$');
  final RegExp pattern;
  final AtOutcome Function(RegExpMatch m, String raw) run;
}

/// データシート（ELM327DSI v2.0）p.9–10 の AT コマンド一覧を 4 段階（動作・保存・OK・?）で扱う。
class AtCommands {
  AtCommands(this.state, {required this.voltage, required this.ignitionOn});

  final ElmState state;
  final double Function() voltage;
  final bool Function() ignitionOn;

  static const _ok = AtReply(['OK']);
  static const _q = AtReply(['?']);
  static const _hx = '[0-9A-F]';

  AtOutcome handle(String body, {String raw = ''}) {
    for (final rule in _rules) {
      final m = rule.pattern.firstMatch(body);
      if (m != null) return rule.run(m, raw);
    }
    return _q;
  }

  AtOutcome _set(void Function() apply) {
    apply();
    return _ok;
  }

  int _h(RegExpMatch m, [int group = 1]) => int.parse(m.group(group)!, radix: 16);
  bool _b(RegExpMatch m) => m.group(1) == '1';

  late final List<_Rule> _rules = [
    // ---- 全般 ----
    _Rule('Z', (m, r) => _reset()),
    _Rule('WS', (m, r) => _reset()),
    _Rule('D', (m, r) => _set(state.defaults)),
    _Rule('I', (m, r) => const AtReply([elmId])),
    _Rule('@1', (m, r) => const AtReply([elmDescription])),
    _Rule('@2', (m, r) => state.deviceId == null ? _q : AtReply([state.deviceId!])),
    _Rule('@3.*', (m, r) => _storeDeviceId(r)),
    _Rule('E([01])', (m, r) => _set(() => state.echo = _b(m))),
    _Rule('L([01])', (m, r) => _set(() => state.linefeed = _b(m))),
    _Rule('M([01])', (m, r) => _set(() => state.memory = _b(m))),
    _Rule('SD($_hx{2})', (m, r) => _set(() => state.storedByte = _h(m))),
    _Rule('RD', (m, r) => AtReply([hex2(state.storedByte)])),
    _Rule('BRD($_hx{2})', (m, r) => _h(m) == 0 ? _q : _ok),
    _Rule('BRT$_hx{2}', (m, r) => _ok),
    _Rule('FE', (m, r) => _ok),
    _Rule('LP', (m, r) => const AtLowPower()),
    _Rule('PP($_hx{2})ON', (m, r) => _set(() => _ppRange(_h(m)).forEach(state.ppEnabled.add))),
    _Rule('PP($_hx{2})OFF', (m, r) => _set(() => _ppRange(_h(m)).forEach(state.ppEnabled.remove))),
    _Rule('PP($_hx{2})SV($_hx{2})', (m, r) => _set(() => state.ppValues[_h(m)] = _h(m, 2))),
    _Rule('PPS', (m, r) => AtReply(_ppSummary())),
    _Rule(r'CV(\d{4})', (m, r) => _calibrate(int.parse(m.group(1)!))),
    _Rule('RV', (m, r) => AtReply(['${(voltage() + (state.voltageOffset ?? 0)).toStringAsFixed(1)}V'])),
    _Rule('IGN', (m, r) => AtReply([ignitionOn() ? 'ON' : 'OFF'])),
    // ---- OBD 全般 ----
    _Rule('AL', (m, r) => _set(() => state.allowLong = true)),
    _Rule('NL', (m, r) => _set(() => state.allowLong = false)),
    _Rule('AMC', (m, r) => AtReply([hex2(_activityCount())])),
    _Rule('AMT($_hx{2})', (m, r) => _set(() => state.activityTimeout = _h(m))),
    _Rule('AR', (m, r) => _set(() => state.receiveAddress = null)),
    _Rule('AT([012])', (m, r) => _set(() => state.timing = AdaptiveTiming.values[int.parse(m.group(1)!)])),
    _Rule('BD', (m, r) => AtReply([_bufferDump()])),
    _Rule('BI', (m, r) => _ok),
    _Rule('DP', (m, r) => AtReply([state.describeProtocol()])),
    _Rule('DPN', (m, r) => AtReply([state.describeProtocolNumber()])),
    _Rule('H([01])', (m, r) => _set(() => state.headers = _b(m))),
    _Rule('MA', (m, r) => const AtMonitor()),
    _Rule('MR($_hx{2})', (m, r) => AtMonitor(receiver: _h(m))),
    _Rule('MT($_hx{2})', (m, r) => AtMonitor(transmitter: _h(m))),
    _Rule('PC', (m, r) => _ok),
    _Rule('R([01])', (m, r) => _set(() => state.responses = _b(m))),
    _Rule('RA($_hx{2})', (m, r) => _set(() => state.receiveAddress = _h(m))),
    _Rule('SR($_hx{2})', (m, r) => _set(() => state.receiveAddress = _h(m))),
    _Rule('S([01])', (m, r) => _set(() => state.spaces = _b(m))),
    _Rule('SH($_hx{3})', (m, r) => _set(() => state.header = _h(m))),
    _Rule('SH($_hx{6})', (m, r) => _set(() => state.header = _h(m))),
    _Rule('SH($_hx{2})($_hx{6})', (m, r) => _set(() {
          state.priority29 = _h(m) & 0x1F;
          state.header = _h(m, 2);
        })),
    _Rule('SP00', (m, r) => _set(() => state.setProtocol(0, auto: true, save: true))),
    _Rule('SP([0-9A-C])', (m, r) => _set(() {
          final p = _h(m);
          state.setProtocol(p, auto: p == 0, save: p != 0);
        })),
    _Rule('SPA([0-9A-C])', (m, r) => _set(() => state.setProtocol(_h(m), auto: true, save: true))),
    _Rule('TP([0-9A-C])', (m, r) => _set(() {
          final p = _h(m);
          state.setProtocol(p, auto: p == 0, save: false);
        })),
    _Rule('TPA([0-9A-C])', (m, r) => _set(() => state.setProtocol(_h(m), auto: true, save: false))),
    _Rule('SS', (m, r) => _ok),
    _Rule('ST($_hx{2})', (m, r) => _set(() => state.timeoutHex = _h(m) == 0 ? 0x32 : _h(m))),
    _Rule('TA($_hx{2})', (m, r) => _set(() => state.testerAddress = _h(m))),
    // ---- CAN ----
    _Rule('CAF([01])', (m, r) => _set(() => state.caf = _b(m))),
    _Rule('CEA', (m, r) => _set(() => state.extendedAddress = null)),
    _Rule('CEA($_hx{2})', (m, r) => _set(() => state.extendedAddress = _h(m))),
    _Rule('CF($_hx{3}|$_hx{8})', (m, r) => _set(() => state.filterId = _h(m))),
    _Rule('CFC([01])', (m, r) => _set(() => state.autoFlowControl = _b(m))),
    _Rule('CM($_hx{3}|$_hx{8})', (m, r) => _set(() => state.maskId = _h(m))),
    _Rule('CP($_hx{2})', (m, r) => _set(() => state.priority29 = _h(m) & 0x1F)),
    _Rule('CRA', (m, r) => _set(() {
          state.craId = null;
          state.filterId = null;
          state.maskId = null;
        })),
    _Rule('CRA($_hx{3}|$_hx{8})', (m, r) => _set(() => state.craId = _h(m))),
    _Rule('CS', (m, r) => AtReply(['T:${hex2(state.txErrors)} R:${hex2(state.rxErrors)}'])),
    _Rule('CSM[01]', (m, r) => _ok),
    _Rule('D([01])', (m, r) => _set(() => state.dlc = _b(m))),
    _Rule('FCSM([0-9])', (m, r) => _setFlowMode(int.parse(m.group(1)!))),
    _Rule('FCSH($_hx{3}|$_hx{8})', (m, r) => _set(() => state.flowHeader = _h(m))),
    _Rule('FCSD((?:$_hx{2}){1,5})', (m, r) => _set(() {
          final s = m.group(1)!;
          state.flowData = [
            for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
          ];
        })),
    _Rule('PB($_hx{2})($_hx{2})', (m, r) => _set(() => state.protocolB = [
          int.parse(m.group(1)!, radix: 16),
          int.parse(m.group(2)!, radix: 16),
        ])),
    _Rule('RTR', (m, r) => const AtRtr()),
    _Rule('V([01])', (m, r) => _set(() => state.variableDlc = _b(m))),
    // ---- J1850 / ISO / J1939（CAN 以外）: 設定は受け付け、実行は ? ----
    _Rule('IFR[012HS]', (m, r) => _ok),
    _Rule('IB(?:10|48|96)', (m, r) => _ok),
    _Rule('IIA$_hx{2}', (m, r) => _ok),
    _Rule('KW[01]', (m, r) => _ok),
    _Rule('SW$_hx{2}', (m, r) => _ok),
    _Rule('WM(?:$_hx{2}){1,6}', (m, r) => _ok),
    _Rule('J[ES]', (m, r) => _ok),
    _Rule('JHF[01]', (m, r) => _ok),
    _Rule('JTM[15]', (m, r) => _ok),
    _Rule('FI', (m, r) => _q),
    _Rule('SI', (m, r) => _q),
    _Rule('KW', (m, r) => _q),
    _Rule('DM1', (m, r) => _q),
    _Rule('MP(?:$_hx{4}|$_hx{6})$_hx?', (m, r) => _q),
  ];

  AtOutcome _reset() {
    state.reset();
    return const AtReset();
  }

  AtOutcome _storeDeviceId(String raw) {
    if (state.deviceId != null) return _q; // 一度設定したら変更できない（p.26）
    final m = RegExp(r'@3\s?(.*)$').firstMatch(raw);
    final id = m?.group(1) ?? '';
    if (id.length != 12) return _q;
    state.deviceId = id;
    return _ok;
  }

  Iterable<int> _ppRange(int n) => n == 0xFF ? List.generate(0x30, (i) => i) : [n];

  List<String> _ppSummary() {
    String item(int n) {
      final value = state.ppValues[n] ?? (n == 0x26 ? 0x00 : 0xFF);
      return '${hex2(n)}:${hex2(value)} ${state.ppEnabled.contains(n) ? 'N' : 'F'}';
    }

    return [
      for (var row = 0; row < 0x30; row += 4)
        [for (var n = row; n < row + 4; n++) item(n)].join('  '),
    ];
  }

  AtOutcome _calibrate(int hundredths) {
    state.voltageOffset = hundredths == 0 ? null : hundredths / 100 - voltage();
    return _ok;
  }

  int _activityCount() {
    final last = state.lastActivity;
    if (last == null) return 0xFF;
    final ticks = clock.now().difference(last).inMicroseconds ~/ 655360;
    return math.min(0xFF, math.max(0, ticks));
  }

  /// 長さ 1 バイト + OBD バッファ 12 バイト（p.12）。ID の格納方法は近似。
  String _bufferDump() {
    final f = state.lastFrame;
    final content = f == null
        ? <int>[]
        : [
            ...(f.extended
                ? [(f.id >> 24) & 0xFF, (f.id >> 16) & 0xFF, (f.id >> 8) & 0xFF, f.id & 0xFF]
                : [(f.id >> 8) & 0x07, f.id & 0xFF]),
            ...f.data,
          ];
    final length = math.min(12, content.length);
    final buffer = [...content.take(12), ...List.filled(12 - length, 0)];
    return [length, ...buffer].map(hex2).join(' ');
  }

  AtOutcome _setFlowMode(int mode) {
    if (mode > 2) return _q;
    if (mode == 1 && (state.flowHeader == null || state.flowData == null)) return _q;
    if (mode == 2 && state.flowData == null) return _q;
    state.flowMode = mode;
    return _ok;
  }
}
