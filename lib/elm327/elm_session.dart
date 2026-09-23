import 'dart:async';

import 'package:clock/clock.dart';

import '../can/can_frame.dart';
import '../can/fault_injector.dart';
import '../can/iso_tp.dart';
import '../can/virtual_can_bus.dart';
import '../util/hex.dart';
import 'at_commands.dart';
import 'elm_state.dart';
import 'line_assembler.dart';
import 'response_formatter.dart';

enum SessionMode { idle, busy, monitoring, lowPower }

class _Pending {
  _Pending({
    required this.expected,
    required this.searching,
    required this.dropped,
    required this.mark,
  });
  final int? expected;
  final bool searching;
  final bool dropped;
  final ElmErrorKind? mark;
  final List<String> lines = [];
  int completed = 0;
  final Map<int, Reassembler> _reassemblers = {};
  Reassembler reassemblerFor(int id) =>
      _reassemblers.putIfAbsent(id, Reassembler.new);
}

class _Monitor {
  const _Monitor(this.receiver, this.transmitter);
  final int? receiver;
  final int? transmitter;
}

/// 1 接続ぶんの ELM327。入力バイトを受け、AT を処理し、OBD/UDS 要求を仮想バスへ送る。
class ElmSession {
  ElmSession({
    required this.bus,
    required this.faults,
    required double Function() voltage,
  }) {
    at = AtCommands(
      state,
      voltage: voltage,
      ignitionOn: () => !faults.config.ignitionOff,
    );
    formatter = ResponseFormatter(state);
    _unlisten = bus.listen(_onBusEvent);
  }

  final VirtualCanBus bus;
  final FaultInjector faults;
  final ElmState state = ElmState();
  late final AtCommands at;
  late final ResponseFormatter formatter;

  static const adaptiveWait = Duration(milliseconds: 50);
  static const pendingWait = Duration(milliseconds: 5000);

  final LineAssembler _assembler = LineAssembler();
  final StreamController<List<int>> _out = StreamController.broadcast(
    sync: true,
  );
  late final void Function() _unlisten;
  SessionMode _mode = SessionMode.idle;
  _Pending? _pending;
  _Monitor? _monitor;
  Timer? _timer;
  bool _disposed = false;

  Stream<List<int>> get output => _out.stream;
  SessionMode get mode => _mode;

  String get _eol => state.linefeed ? '\r\n' : '\r';

  void input(List<int> bytes) {
    if (_disposed) return;
    for (final b in bytes) {
      switch (_mode) {
        case SessionMode.lowPower:
          _mode = SessionMode.idle; // 起こした文字は捨てる
        case SessionMode.busy:
        case SessionMode.monitoring:
          if (b == 0x0A || b == 0x00) continue; // 変更点 9
          _stop();
        case SessionMode.idle:
          for (final line in _assembler.addBytes([b])) {
            _processLine(line);
          }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _unlisten();
    _out.close();
  }

  void _emit(String s) {
    if (!_disposed) _out.add(s.codeUnits);
  }

  void _finish(List<String> lines) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _monitor = null;
    _mode = SessionMode.idle;
    _emit('${lines.map((l) => '$l$_eol').join()}$_eol>');
  }

  void _stop() => _finish(const ['STOPPED']);

  void _processLine(String raw) {
    if (state.echo) _emit('$raw\r');
    var text = raw.toUpperCase().replaceAll(' ', '');
    if (text.isEmpty) {
      final last = state.lastCommand;
      if (last == null) {
        _emit('>');
        return;
      }
      text = last;
    } else {
      state.lastCommand = text;
    }
    if (text.startsWith('AT')) {
      _handleAt(text.substring(2), raw);
    } else {
      _handleRequest(text);
    }
  }

  void _handleAt(String body, String raw) {
    switch (at.handle(body, raw: raw)) {
      case AtReply(:final lines):
        _finish(lines);
      case AtReset():
        formatter.reset();
        _finish(const ['', '', elmId]);
      case AtLowPower():
        _finish(const ['OK']);
        _mode = SessionMode.lowPower;
      case AtMonitor(:final receiver, :final transmitter):
        formatter.reset();
        _monitor = _Monitor(receiver, transmitter);
        _mode = SessionMode.monitoring;
      case AtRtr():
        bus.transmit(
          CanFrame(state.txId, const [], extended: state.is29bit, rtr: true),
          sender: this,
        );
        _finish(const []);
    }
  }

  void _handleRequest(String text) {
    var hexText = text;
    int? expected;
    if (hexText.length.isOdd) {
      final n = int.tryParse(hexText[hexText.length - 1], radix: 16);
      if (n == null || n == 0) {
        _finish(const ['?']);
        return;
      }
      expected = n;
      hexText = hexText.substring(0, hexText.length - 1);
    }
    final payload = parseHexBytes(hexText);
    final maxLength =
        (state.caf ? 7 : 8) - (state.extendedAddress == null ? 0 : 1);
    if (payload == null || payload.length > maxLength) {
      _finish(const ['?']);
      return;
    }

    final protocol = state.activeProtocol;
    if (!ElmState.isCanProtocol(protocol)) {
      _finish([
        protocol >= 3 && protocol <= 5 ? 'BUS INIT: ...ERROR' : 'NO DATA',
      ]);
      return;
    }
    final searching = state.autoSearch && state.established == null;
    if (searching) _emit('SEARCHING...$_eol');

    final error = faults.takeError();
    if (error != null) {
      state.txErrors++;
      if (!error.isMark) {
        if (error.resetsState) state.reset();
        _finish([error.text]);
        return;
      }
    }

    final data = <int>[
      if (state.extendedAddress != null) state.extendedAddress!,
      if (state.caf) payload.length,
      ...payload,
    ];
    final padded = state.variableDlc
        ? data
        : [...data, ...List.filled(8 - data.length, canPadByte)];
    final frame = CanFrame(state.txId, padded, extended: state.is29bit);
    state
      ..lastFrame = frame
      ..lastActivity = clock.now();
    formatter.reset();
    _mode = SessionMode.busy;
    _pending = _Pending(
      expected: expected,
      searching: searching,
      dropped: faults.rollDrop(),
      mark: error != null && error.isMark ? error : null,
    );
    bus.transmit(frame, sender: this);
    if (!state.responses) {
      _finish(const []);
      return;
    }
    _arm(state.timeout);
  }

  void _arm(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _complete);
  }

  void _onBusEvent(BusEvent e) {
    if (_disposed || identical(e.sender, this)) return;
    final f = e.frame;
    if (_mode == SessionMode.monitoring) {
      _onMonitorFrame(f);
      return;
    }
    final p = _pending;
    if (_mode != SessionMode.busy || p == null) return;
    if (p.dropped || !state.acceptsResponse(f)) return;
    state
      ..lastFrame = f
      ..lastActivity = clock.now();
    p.lines.addAll(formatter.frameLines(f));
    if (frameType(f.data) == FrameType.first && state.autoFlowControl) {
      bus.transmit(
        CanFrame(_flowControlId(f), flowControl(), extended: f.extended),
        sender: this,
      );
    }
    final message = p.reassemblerFor(f.id).add(f.data);
    if (message != null) {
      if (message.length == 3 && message[0] == 0x7F && message[2] == 0x78) {
        _arm(pendingWait); // 応答保留（未確認 4）
        return;
      }
      p.completed++;
      final expected = p.expected;
      if (expected != null && p.completed >= expected) {
        _complete();
        return;
      }
    }
    final wait =
        state.timing == AdaptiveTiming.off || state.timeout < adaptiveWait
        ? state.timeout
        : adaptiveWait;
    _arm(wait);
  }

  void _onMonitorFrame(CanFrame f) {
    final m = _monitor;
    if (m == null) return;
    if (!state.acceptsMonitor(
      f,
      receiver: m.receiver,
      transmitter: m.transmitter,
    )) {
      return;
    }
    for (final line in formatter.frameLines(f, monitor: true)) {
      _emit('$line$_eol');
    }
  }

  int _flowControlId(CanFrame f) => f.extended
      ? (f.id & 0xFFFF0000) | ((f.id & 0xFF) << 8) | ((f.id >> 8) & 0xFF)
      : f.id - 8;

  void _complete() {
    final p = _pending;
    if (p == null) return;
    var lines = List<String>.of(p.lines);
    if (lines.isEmpty) {
      lines = [
        p.searching
            ? 'UNABLE TO CONNECT'
            : (faults.config.ignitionOff ? 'CAN ERROR' : 'NO DATA'),
      ];
    } else {
      if (p.searching) state.established = state.activeProtocol;
      final mark = p.mark;
      if (mark != null) {
        final last = lines.removeLast();
        lines.add(
          last.endsWith(' ') ? '$last${mark.text}' : '$last ${mark.text}',
        );
      }
    }
    _finish(lines);
  }
}
