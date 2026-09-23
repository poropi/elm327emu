import 'dart:async';

import '../can/can_frame.dart';
import '../can/fault_injector.dart';
import '../can/iso_tp.dart';
import '../can/virtual_can_bus.dart';
import 'ecu_profile.dart';
import 'obd_services.dart';
import 'uds_services.dart';

enum _Addressing { functional, physical }

/// 1 要求者（セッション）ぶんの ISO-TP 送信状態。
class _Transfer {
  _Transfer(this.id, this.extended, this.remaining);
  final int id;
  final bool extended;
  final List<List<int>> remaining;
  int blockLeft = 0;
  Duration gap = const Duration(milliseconds: 1);
  Timer? fcTimeout;
  Timer? next;

  void cancel() {
    fcTimeout?.cancel();
    next?.cancel();
  }
}

/// バス上の ECU。要求フレームを受け、遅延ののち ISO-TP で応答する。
///
/// 応答は要求の送信元（[BusEvent.sender]）を [BusEvent.replyTo] に付けて送る。
/// 複数フレームの送信状態は要求者ごとに持ち、FC はそれを送った要求者の送信にだけ効く
/// （同じバスを共有する複数セッションが同時に要求しても混ざらない）。
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
  final Map<Object?, _Transfer> _transfers = Map.identity();

  /// FC 待ち・CF 送信中の複数フレーム応答の数（要求者ごと）。
  int get pendingTransfers => _transfers.length;

  @override
  void onEvent(BusEvent event) {
    final frame = event.frame;
    if (!profile.enabled || faults.isSilent(profile) || frame.rtr) return;
    final addressing = _addressing(frame);
    if (addressing == null) return;
    final requester = event.sender;
    final type = frameType(frame.data);
    if (type == FrameType.flowControl) {
      if (addressing == _Addressing.physical) {
        _onFlowControl(requester, frame.data);
      }
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
    void send(List<int> payload) =>
        _send(requester, responseId, frame.extended, payload);
    if (faults.config.responsePending && !functional) {
      _schedule(delay, () => send([0x7F, request[0], 0x78]));
      _schedule(delay + pendingDelay, () => send(response));
    } else {
      _schedule(delay, () => send(response));
    }
  }

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final tr in _transfers.values) {
      tr.cancel();
    }
    _transfers.clear();
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

  void _send(Object? requester, int id, bool extended, List<int> payload) {
    if (!profile.enabled || faults.isSilent(profile)) return;
    final frames = segment(payload);
    // FF を送る前に残りを登録する（FC は FF の配信中に同期で返ってくる）。
    // 同じ要求者への前の複数フレームは、新しい複数フレームで置き換える。
    if (frames.length > 1 && !faults.config.truncateMultiFrame) {
      _drop(requester);
      final tr = _Transfer(id, extended, frames.sublist(1));
      _transfers[requester] = tr;
      _armFlowControlTimeout(requester, tr);
    }
    bus.transmit(
      CanFrame(id, frames.first, extended: extended),
      sender: this,
      replyTo: requester,
    );
  }

  void _drop(Object? requester) => _transfers.remove(requester)?.cancel();

  void _armFlowControlTimeout(Object? requester, _Transfer tr) {
    tr.fcTimeout?.cancel();
    tr.fcTimeout = Timer(flowControlTimeout, () {
      if (identical(_transfers[requester], tr)) _transfers.remove(requester);
    });
  }

  void _onFlowControl(Object? requester, List<int> data) {
    final tr = _transfers[requester];
    if (tr == null || tr.next != null) return; // CF 送信中の FC は無視する
    final status = data[0] & 0x0F;
    if (status == 1) {
      _armFlowControlTimeout(requester, tr); // Wait
      return;
    }
    tr.fcTimeout?.cancel();
    if (status != 0) {
      _drop(requester); // Overflow など
      return;
    }
    final blockSize = data.length > 1 ? data[1] : 0;
    final stMin = data.length > 2 ? data[2] : 0;
    tr.gap = Duration(milliseconds: stMin >= 1 && stMin <= 0x7F ? stMin : 1);
    tr.blockLeft = blockSize;
    _sendNextConsecutive(requester, tr);
  }

  void _sendNextConsecutive(Object? requester, _Transfer tr) {
    tr.next = Timer(tr.gap, () {
      tr.next = null;
      if (!identical(_transfers[requester], tr)) return;
      bus.transmit(
        CanFrame(tr.id, tr.remaining.removeAt(0), extended: tr.extended),
        sender: this,
        replyTo: requester,
      );
      if (tr.remaining.isEmpty) {
        _transfers.remove(requester);
        return;
      }
      if (tr.blockLeft > 0) {
        tr.blockLeft--;
        if (tr.blockLeft == 0) {
          _armFlowControlTimeout(requester, tr);
          return;
        }
      }
      _sendNextConsecutive(requester, tr);
    });
  }
}
