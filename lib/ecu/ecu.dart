import 'dart:async';

import '../can/can_frame.dart';
import '../can/fault_injector.dart';
import '../can/iso_tp.dart';
import '../can/virtual_can_bus.dart';
import 'ecu_profile.dart';
import 'obd_services.dart';
import 'uds_services.dart';

enum _Addressing { functional, physical }

/// バス上の ECU。要求フレームを受け、遅延ののち ISO-TP で応答する。
class Ecu implements BusNode {
  Ecu({
    required this.profile,
    required this.bus,
    required this.obd,
    required this.uds,
    required this.faults,
  });

  final EcuProfile profile;
  final VirtualCanBus bus;
  final ObdServices obd;
  final UdsServices uds;
  final FaultInjector faults;

  static const flowControlTimeout = Duration(milliseconds: 1000);
  static const pendingDelay = Duration(milliseconds: 1000);

  final List<Timer> _timers = [];
  List<List<int>> _remaining = [];
  int _txId = 0;
  bool _txExtended = false;
  int _blockLeft = 0;
  Duration _gap = const Duration(milliseconds: 1);
  Timer? _fcTimeout;

  @override
  void onFrame(CanFrame frame) {
    if (!profile.enabled || faults.isSilent(profile) || frame.rtr) return;
    final addressing = _addressing(frame);
    if (addressing == null) return;
    final type = frameType(frame.data);
    if (type == FrameType.flowControl) {
      if (addressing == _Addressing.physical) _onFlowControl(frame.data);
      return;
    }
    if (type != FrameType.single) return;
    final n = frame.data[0] & 0x0F;
    final request = frame.data.sublist(1, 1 + n);
    final functional = addressing == _Addressing.functional;
    final response = request[0] <= 0x0A
        ? obd.handle(request, profile)
        : uds.handle(request, profile, functional: functional);
    if (response == null) return;
    final responseId = frame.extended
        ? profile.responseId29For(frame.id & 0xFF)
        : profile.responseId11;
    final delay = profile.baseLatency + faults.extraDelay;
    if (faults.config.responsePending && !functional) {
      _schedule(
        delay,
        () => _send(responseId, frame.extended, [0x7F, request[0], 0x78]),
      );
      _schedule(
        delay + pendingDelay,
        () => _send(responseId, frame.extended, response),
      );
    } else {
      _schedule(delay, () => _send(responseId, frame.extended, response));
    }
  }

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _fcTimeout?.cancel();
    bus.detach(this);
  }

  _Addressing? _addressing(CanFrame f) {
    if (!f.extended) {
      if (f.id == functionalId11) return _Addressing.functional;
      if (f.id == profile.requestId11) return _Addressing.physical;
      return null;
    }
    final middle = f.id & 0x00FFFF00;
    if (middle == 0x00DB3300) return _Addressing.functional;
    if (middle == (0x00DA0000 | (profile.address29 << 8))) {
      return _Addressing.physical;
    }
    return null;
  }

  void _schedule(Duration delay, void Function() fn) {
    late final Timer t;
    t = Timer(delay, () {
      _timers.remove(t);
      fn();
    });
    _timers.add(t);
  }

  void _send(int id, bool extended, List<int> payload) {
    if (!profile.enabled || faults.isSilent(profile)) return;
    final frames = segment(payload);
    // FF を送る前に残りを登録する（FC は FF の配信中に同期で返ってくる）。
    if (frames.length > 1 && !faults.config.truncateMultiFrame) {
      _remaining = frames.sublist(1);
      _txId = id;
      _txExtended = extended;
      _armFlowControlTimeout();
    }
    bus.transmit(CanFrame(id, frames.first, extended: extended), sender: this);
  }

  void _armFlowControlTimeout() {
    _fcTimeout?.cancel();
    _fcTimeout = Timer(flowControlTimeout, () => _remaining = []);
  }

  void _onFlowControl(List<int> data) {
    if (_remaining.isEmpty) return;
    final status = data[0] & 0x0F;
    if (status == 1) {
      _armFlowControlTimeout(); // Wait
      return;
    }
    _fcTimeout?.cancel();
    if (status != 0) {
      _remaining = []; // Overflow など
      return;
    }
    final blockSize = data.length > 1 ? data[1] : 0;
    final stMin = data.length > 2 ? data[2] : 0;
    _gap = Duration(milliseconds: stMin >= 1 && stMin <= 0x7F ? stMin : 1);
    _blockLeft = blockSize;
    _sendNextConsecutive();
  }

  void _sendNextConsecutive() {
    _schedule(_gap, () {
      if (_remaining.isEmpty) return;
      bus.transmit(
        CanFrame(_txId, _remaining.removeAt(0), extended: _txExtended),
        sender: this,
      );
      if (_remaining.isEmpty) return;
      if (_blockLeft > 0) {
        _blockLeft--;
        if (_blockLeft == 0) {
          _armFlowControlTimeout();
          return;
        }
      }
      _sendNextConsecutive();
    });
  }
}
