import '../can/can_frame.dart';
import '../can/iso_tp.dart';
import '../util/hex.dart';
import 'elm_state.dart';

/// 受信フレームを ELM327 の表示行にする（設計 §7.1）。
class ResponseFormatter {
  ResponseFormatter(this.state);
  final ElmState state;

  /// H0 かつ CAF1 の複数フレーム表示で、送信元 ID ごとに残りバイト数を覚える。
  final Map<int, int> _remaining = {};

  void reset() => _remaining.clear();

  String bytes(List<int> data) =>
      state.spaces ? '${data.map(hex2).join(' ')} ' : data.map(hex2).join();

  String idText(CanFrame f) {
    if (!f.extended) return hexN(f.id, 3);
    final parts = [(f.id >> 24) & 0xFF, (f.id >> 16) & 0xFF, (f.id >> 8) & 0xFF, f.id & 0xFF]
        .map(hex2);
    return state.spaces ? parts.join(' ') : parts.join();
  }

  List<String> frameLines(CanFrame f, {bool monitor = false}) {
    final sep = state.spaces ? ' ' : '';
    if (state.headers || !state.caf || monitor) {
      final head = state.headers
          ? '${idText(f)}$sep${state.dlc ? '${f.dlc}$sep' : ''}'
          : '';
      if (f.rtr) return state.headers || !state.caf ? ['${head}RTR'] : [];
      final fc = monitor && frameType(f.data) == FrameType.flowControl ? 'FC:$sep' : '';
      return ['$head$fc${bytes(f.data)}'];
    }
    if (f.rtr) return [];
    switch (frameType(f.data)) {
      case FrameType.single:
        final n = f.data[0] & 0x0F;
        return [bytes(f.data.sublist(1, 1 + n))];
      case FrameType.first:
        final total = ((f.data[0] & 0x0F) << 8) | f.data[1];
        final first = f.data.sublist(2);
        _remaining[f.id] = total - first.length;
        return [hexN(total, 3), '0:$sep${bytes(first)}'];
      case FrameType.consecutive:
        final rem = _remaining[f.id];
        if (rem == null || rem <= 0) return [];
        final take = rem < f.data.length - 1 ? rem : f.data.length - 1;
        _remaining[f.id] = rem - take;
        return ['${hexN(f.data[0] & 0x0F, 1)}:$sep${bytes(f.data.sublist(1, 1 + take))}'];
      case FrameType.flowControl:
      case FrameType.invalid:
        return [];
    }
  }
}
