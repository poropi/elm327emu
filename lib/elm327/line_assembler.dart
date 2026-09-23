/// 受信バイト列を CR 区切りのコマンド行に組み立てる。
/// 空行は '' として返す（直前のコマンドの繰り返しに使う）。LF・NUL などの制御文字は捨てる。
class LineAssembler {
  final StringBuffer _buf = StringBuffer();

  List<String> addBytes(List<int> bytes) {
    final lines = <String>[];
    for (final byte in bytes) {
      if (byte == 0x0D) {
        lines.add(_buf.toString());
        _buf.clear();
      } else if (byte >= 0x20) {
        _buf.writeCharCode(byte);
      }
    }
    return lines;
  }
}
