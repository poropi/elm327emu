/// 16 進の表示と解析。
String hex2(int v) =>
    (v & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0');

String hexN(int v, int width) =>
    v.toRadixString(16).toUpperCase().padLeft(width, '0');

final _hexPattern = RegExp(r'^[0-9A-Fa-f]+$');

/// "010C" → [0x01, 0x0C]。空・奇数桁・16 進以外は null。
List<int>? parseHexBytes(String s) {
  if (s.isEmpty || s.length.isOdd || !_hexPattern.hasMatch(s)) return null;
  return [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];
}
