/// CAN フレーム 1 つ。11bit ID（0〜0x7FF）または 29bit ID（0〜0x1FFFFFFF）と、データ 0〜8 バイト。
class CanFrame {
  CanFrame(this.id, List<int> data, {this.extended = false, this.rtr = false})
    : data = List.unmodifiable(data) {
    if (data.length > 8) {
      throw ArgumentError.value(data.length, 'data', 'CAN のデータは 8 バイトまで');
    }
    final max = extended ? 0x1FFFFFFF : 0x7FF;
    if (id < 0 || id > max) {
      throw ArgumentError.value(id, 'id', 'ID の範囲外');
    }
  }

  final int id;
  final bool extended;
  final bool rtr;
  final List<int> data;

  int get dlc => data.length;

  @override
  bool operator ==(Object other) =>
      other is CanFrame &&
      other.id == id &&
      other.extended == extended &&
      other.rtr == rtr &&
      _sameBytes(other.data, data);

  @override
  int get hashCode => Object.hash(id, extended, rtr, Object.hashAll(data));

  @override
  String toString() {
    final idText = id
        .toRadixString(16)
        .toUpperCase()
        .padLeft(extended ? 8 : 3, '0');
    final bytes = data
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
    return '$idText [${data.length}] $bytes${rtr ? ' RTR' : ''}';
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
