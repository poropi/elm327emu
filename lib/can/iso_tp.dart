/// ISO 15765-2（ISO-TP）の分割・種類判定・復元。
const int canPadByte = 0x00;

List<int> _pad(List<int> d) =>
    d.length >= 8 ? d : [...d, ...List.filled(8 - d.length, canPadByte)];

/// ペイロードをフレームのデータ列に分割する（ECU 側）。7 バイト以下は SF 1 つ。
List<List<int>> segment(List<int> payload, {bool pad = true}) {
  if (payload.isEmpty || payload.length > 4095) {
    throw ArgumentError.value(payload.length, 'payload', 'ISO-TP は 1〜4095 バイト');
  }
  List<int> p(List<int> d) => pad ? _pad(d) : d;
  if (payload.length <= 7) {
    return [
      p([payload.length, ...payload]),
    ];
  }
  final out = <List<int>>[
    p([
      0x10 | (payload.length >> 8),
      payload.length & 0xFF,
      ...payload.sublist(0, 6),
    ]),
  ];
  var seq = 1;
  for (var i = 6; i < payload.length; i += 7) {
    final end = i + 7 < payload.length ? i + 7 : payload.length;
    out.add(p([0x20 | (seq & 0x0F), ...payload.sublist(i, end)]));
    seq++;
  }
  return out;
}

/// フロー制御フレーム（Continue To Send）。
List<int> flowControl({int blockSize = 0, int stMin = 0}) =>
    _pad([0x30, blockSize & 0xFF, stMin & 0xFF]);

enum FrameType { single, first, consecutive, flowControl, invalid }

FrameType frameType(List<int> data) {
  if (data.isEmpty) return FrameType.invalid;
  switch (data[0] >> 4) {
    case 0:
      final n = data[0] & 0x0F;
      return n >= 1 && n <= 7 && n < data.length
          ? FrameType.single
          : FrameType.invalid;
    case 1:
      return data.length >= 3 ? FrameType.first : FrameType.invalid;
    case 2:
      return FrameType.consecutive;
    case 3:
      return FrameType.flowControl;
    default:
      return FrameType.invalid;
  }
}

/// 1 送信元ぶんの復元器（ELM 側）。
class Reassembler {
  int? _total;
  final List<int> _buf = [];
  int _nextSeq = 1;

  bool get inProgress => _total != null;

  /// フレームのデータを入れる。メッセージが完成したらペイロードを返す。
  List<int>? add(List<int> data) {
    switch (frameType(data)) {
      case FrameType.single:
        _reset();
        final n = data[0] & 0x0F;
        return data.sublist(1, 1 + n);
      case FrameType.first:
        _total = ((data[0] & 0x0F) << 8) | data[1];
        _buf
          ..clear()
          ..addAll(data.sublist(2));
        _nextSeq = 1;
        return null;
      case FrameType.consecutive:
        final total = _total;
        if (total == null) return null;
        if ((data[0] & 0x0F) != (_nextSeq & 0x0F)) {
          _reset();
          return null;
        }
        _nextSeq++;
        final remaining = total - _buf.length;
        final take = remaining < data.length - 1 ? remaining : data.length - 1;
        _buf.addAll(data.sublist(1, 1 + take));
        if (_buf.length >= total) {
          final message = List<int>.of(_buf);
          _reset();
          return message;
        }
        return null;
      case FrameType.flowControl:
      case FrameType.invalid:
        return null;
    }
  }

  void _reset() {
    _total = null;
    _buf.clear();
    _nextSeq = 1;
  }
}
