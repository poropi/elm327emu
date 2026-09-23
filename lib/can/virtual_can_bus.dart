import 'can_frame.dart';

/// バスにつながる機器（ECU など）。
abstract class BusNode {
  void onEvent(BusEvent event);
}

/// バスを流れたフレームと、その送信元。
///
/// [replyTo] は、そのフレームがどの要求者（セッション）への応答かを表す。
/// 仮想 ECU の応答にだけ付く。実在のバスにはない情報で、同じバスを共有する
/// 複数セッションの要求・応答を分けるために使う（null は宛先なし＝誰への応答でもない）。
class BusEvent {
  const BusEvent(this.frame, this.sender, {this.replyTo});
  final CanFrame frame;
  final Object? sender;
  final Object? replyTo;
}

/// 仮想 CAN バス。送信されたフレームを、まず全リスナーへ、次に送信元以外の全ノードへ同期で配る。
/// 応答の遅延は各ノードが Timer で作る。配信中の transmit（再入）も受け付ける。
class VirtualCanBus {
  final List<BusNode> _nodes = [];
  final List<void Function(BusEvent)> _listeners = [];

  void attach(BusNode node) => _nodes.add(node);
  void detach(BusNode node) => _nodes.remove(node);

  /// 全フレームを受け取る。戻り値を呼ぶと解除する。
  void Function() listen(void Function(BusEvent) onEvent) {
    _listeners.add(onEvent);
    return () => _listeners.remove(onEvent);
  }

  void transmit(CanFrame frame, {Object? sender, Object? replyTo}) {
    final event = BusEvent(frame, sender, replyTo: replyTo);
    for (final l in List.of(_listeners)) {
      l(event);
    }
    for (final node in List.of(_nodes)) {
      if (!identical(node, sender)) node.onEvent(event);
    }
  }
}
