import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/iso_tp.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/elm327/response_formatter.dart';

final _vin = [0x49, 0x02, 0x01, ...'WAUZZZ8K9AA000000'.codeUnits];

void main() {
  late ElmState s;
  late ResponseFormatter fmt;
  setUp(() {
    s = ElmState();
    fmt = ResponseFormatter(s);
  });

  CanFrame sf(List<int> payload, {int id = 0x7E8, bool ext = false}) =>
      CanFrame(id, segment(payload).single, extended: ext);
  List<String> vinLines({int id = 0x7E8}) => [
    for (final d in segment(_vin)) ...fmt.frameLines(CanFrame(id, d)),
  ];

  test('H0 CAF1 単一フレーム: データのみ・行末スペース', () {
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['41 0C 21 98 ']);
  });

  test('H0 CAF1 複数フレーム: 総バイト数と連番（FF は 6 バイト、最終のパディングは除く）', () {
    expect(vinLines(), [
      '014',
      '0: 49 02 01 57 41 55 ',
      '1: 5A 5A 5A 38 4B 39 41 ',
      '2: 41 30 30 30 30 30 30 ',
    ]);
  });

  test('H1: ID・PCI・8 バイト全部（p.40 の例と同じ形）', () {
    s.headers = true;
    expect(fmt.frameLines(sf([0x41, 0x05, 0x46])), [
      '7E8 03 41 05 46 00 00 00 00 ',
    ]);
    expect(vinLines(), [
      '7E8 10 14 49 02 01 57 41 55 ',
      '7E8 21 5A 5A 5A 38 4B 39 41 ',
      '7E8 22 41 30 30 30 30 30 30 ',
    ]);
  });

  test('H1 の 29bit ID は 4 バイト区切り', () {
    s
      ..headers = true
      ..setProtocol(7, auto: false, save: false);
    expect(
      fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98], id: 0x18DAF110, ext: true)),
      ['18 DA F1 10 04 41 0C 21 98 00 00 00 '],
    );
  });

  test('S0 + 29bit ヘッダは区切りなしで 8 桁連続', () {
    s
      ..headers = true
      ..spaces = false
      ..setProtocol(7, auto: false, save: false);
    expect(
      fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98], id: 0x18DAF110, ext: true)),
      ['18DAF11004410C2198000000'],
    );
  });

  test('H0 CAF0: PCI とパディングも表示', () {
    s.caf = false;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), [
      '04 41 0C 21 98 00 00 00 ',
    ]);
  });

  test('D1 は H1 のときだけ DLC を表示（p.13）', () {
    s.dlc = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['41 0C 21 98 ']);
    s.headers = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), [
      '7E8 8 04 41 0C 21 98 00 00 00 ',
    ]);
  });

  test('S0 は区切りなし', () {
    s.spaces = false;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['410C2198']);
    expect(vinLines()[1], '0:490201574155');
    s.headers = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), [
      '7E804410C2198000000',
    ]);
  });

  test('2 つの ECU の複数フレームが交互に届いても ID ごとに残りを数える（p.44）', () {
    final a = segment(_vin);
    final b = segment([0x49, 0x04, 0x01, ...List.filled(16, 0x41)]);
    final lines = [
      ...fmt.frameLines(CanFrame(0x7E8, a[0])),
      ...fmt.frameLines(CanFrame(0x7E9, b[0])),
      ...fmt.frameLines(CanFrame(0x7E8, a[1])),
      ...fmt.frameLines(CanFrame(0x7E9, b[1])),
      ...fmt.frameLines(CanFrame(0x7E8, a[2])),
      ...fmt.frameLines(CanFrame(0x7E9, b[2])),
    ];
    expect(lines, [
      '014', '0: 49 02 01 57 41 55 ', //
      '013', '0: 49 04 01 41 41 41 ',
      '1: 5A 5A 5A 38 4B 39 41 ',
      '1: 41 41 41 41 41 41 41 ',
      '2: 41 30 30 30 30 30 30 ',
      '2: 41 41 41 41 41 41 ',
    ]);
  });

  test('FF なしの CF・FC・不正 PCI は H0 CAF1 では表示しない', () {
    expect(
      fmt.frameLines(CanFrame(0x7E8, [0x21, 1, 2, 3, 4, 5, 6, 7])),
      isEmpty,
    );
    expect(fmt.frameLines(CanFrame(0x7E8, flowControl())), isEmpty);
    expect(
      fmt.frameLines(CanFrame(0x7E8, [0x00, 0, 0, 0, 0, 0, 0, 0])),
      isEmpty,
    );
  });

  test('監視中: 生の 8 バイト、FC は "FC: " 付き（p.45）', () {
    expect(
      fmt.frameLines(
        CanFrame(0x0C9, [0x0C, 0x80, 0x1E, 0, 0, 0, 0, 0]),
        monitor: true,
      ),
      ['0C 80 1E 00 00 00 00 00 '],
    );
    s.headers = true;
    expect(fmt.frameLines(CanFrame(0x7E0, flowControl()), monitor: true), [
      '7E0 FC: 30 00 00 00 00 00 00 00 ',
    ]);
  });

  test('監視中 H0: ID は出さず FC: 付きで生の 8 バイト', () {
    expect(fmt.frameLines(CanFrame(0x7E0, flowControl()), monitor: true), [
      'FC: 30 00 00 00 00 00 00 00 ',
    ]);
  });

  test('RTR: CAF1 かつ H0 では出さない、H1 なら ID と RTR（p.45）', () {
    final rtr = CanFrame(0x7DF, [], rtr: true);
    expect(fmt.frameLines(rtr, monitor: true), isEmpty);
    s.headers = true;
    expect(fmt.frameLines(rtr, monitor: true), ['7DF RTR']);
  });

  test('reset で複数フレームの途中状態を消す', () {
    fmt.frameLines(CanFrame(0x7E8, segment(_vin)[0]));
    fmt.reset();
    expect(fmt.frameLines(CanFrame(0x7E8, segment(_vin)[1])), isEmpty);
  });
}
