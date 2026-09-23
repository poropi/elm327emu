/// DTC 文字列（P0301 など）と 2 バイト表現の変換（SAE J1979）。
const _letters = ['P', 'C', 'B', 'U'];
final _dtcPattern = RegExp(r'^[PCBU][0-3][0-9A-F]{3}$');

bool isValidDtc(String code) => _dtcPattern.hasMatch(code);

List<int> dtcToBytes(String code) {
  if (!isValidDtc(code)) {
    throw ArgumentError.value(code, 'code', 'DTC の形式ではない');
  }
  final letter = _letters.indexOf(code[0]);
  final d1 = int.parse(code[1]);
  final d2 = int.parse(code[2], radix: 16);
  final d3 = int.parse(code[3], radix: 16);
  final d4 = int.parse(code[4], radix: 16);
  return [(letter << 6) | (d1 << 4) | d2, (d3 << 4) | d4];
}

String dtcFromBytes(int a, int b) {
  final letter = _letters[(a >> 6) & 0x03];
  final digits = [
    (a >> 4) & 0x03,
    a & 0x0F,
    (b >> 4) & 0x0F,
    b & 0x0F,
  ].map((d) => d.toRadixString(16).toUpperCase()).join();
  return '$letter$digits';
}
