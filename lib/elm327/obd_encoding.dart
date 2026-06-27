String toHex2(int v) =>
    (v & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0');

String _toHex3(int v) =>
    (v & 0xFFF).toRadixString(16).toUpperCase().padLeft(3, '0');

int rpmA(int rpm) => ((rpm * 4) >> 8) & 0xFF;
int rpmB(int rpm) => (rpm * 4) & 0xFF;

const _dtcLetters = ['P', 'C', 'B', 'U'];

List<int> dtcToBytes(String dtc) {
  final letter = _dtcLetters.indexOf(dtc[0]);
  final d1 = int.parse(dtc[1], radix: 16);
  final d2 = int.parse(dtc[2], radix: 16);
  final d3 = int.parse(dtc[3], radix: 16);
  final d4 = int.parse(dtc[4], radix: 16);
  final a = (letter << 6) | (d1 << 4) | d2;
  final b = (d3 << 4) | d4;
  return [a, b];
}

String dtcFromBytes(int a, int bb) {
  final letter = _dtcLetters[(a >> 6) & 0x03];
  final d1 = (a >> 4) & 0x03;
  final d2 = a & 0x0F;
  final d3 = (bb >> 4) & 0x0F;
  final d4 = bb & 0x0F;
  return '$letter${d1.toRadixString(16)}${d2.toRadixString(16)}'
      '${d3.toRadixString(16)}${d4.toRadixString(16)}'.toUpperCase();
}

String formatBytes(List<int> dataBytes, {required bool spaces}) {
  final hex = dataBytes.map(toHex2);
  if (spaces) {
    return '${hex.join(' ')} ';
  }
  return hex.join();
}

/// ELM327 のマルチフレーム表示。7バイト以下なら spaces付き1行、
/// それ超は総バイト数(3桁hex) + "N: <7バイト>" 行。
List<String> isoTpMultiline(List<int> dataBytes) {
  if (dataBytes.length <= 7) {
    return [formatBytes(dataBytes, spaces: true)];
  }
  final lines = <String>[_toHex3(dataBytes.length)];
  var idx = 0;
  for (var i = 0; i < dataBytes.length; i += 7) {
    final chunk = dataBytes.sublist(i, (i + 7).clamp(0, dataBytes.length));
    final hexIdx = idx.toRadixString(16).toUpperCase();
    lines.add('$hexIdx: ${formatBytes(chunk, spaces: true)}');
    idx++;
  }
  return lines;
}
