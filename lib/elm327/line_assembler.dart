/// 受信バイト列を `\r` 区切りでコマンド行に組み立てる。
/// Transport ごとに 1 インスタンスを使う（バッファを分離するため）。
class LineAssembler {
  final StringBuffer _buf = StringBuffer();

  List<String> addBytes(List<int> bytes) {
    final lines = <String>[];
    for (final byte in bytes) {
      if (byte == 0x0D) {
        final line = _buf.toString().trim();
        _buf.clear();
        if (line.isNotEmpty) lines.add(line);
      } else if (byte == 0x0A) {
        // LF は無視
      } else {
        _buf.writeCharCode(byte);
      }
    }
    return lines;
  }
}
