# ELM327 エミュレータ完全化 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 既存の ELM327 エミュレータを、仮想 CAN バス・ECU 2 台・AT コマンド全項目・障害注入・6 タブ UI・開発用 TCP 経路を備えた形に作り直し、python-OBD で端から端まで通ることを確かめる。

**Architecture:** クライアントの入力は接続ごとの `ElmSession` が受け、AT は `AtCommands`、OBD/UDS 要求は ISO-TP の単一フレームにして `VirtualCanBus` へ送る。`Ecu`（エンジン・トランスミッション）が `ObdServices` / `UdsServices` で応答を作り、`FaultInjector` の設定に従って遅延・無応答などを起こす。受信フレームは `ResponseFormatter` が AT 設定どおりに文字列化する。Flutter 非依存の中核（`lib/can`, `lib/ecu`, `lib/elm327`, `lib/vehicle`, `lib/util`, `lib/app/emulation_core.dart`, `lib/app/control_commands.dart`, `lib/transport/tcp_transport.dart`）を、Flutter アプリと UI なしの CLI（`bin/elm327_tcp.dart`）の両方から使う。

**Tech Stack:** Flutter 3.44.6 / Dart ^3.11.5、provider、clock（時刻の抽象）、fake_async（テストの時間制御）、args（CLI）、Kotlin（Android BLE/SPP）、Swift（macOS CoreBluetooth）、python-OBD 0.7.3（検証のみ）

**Spec:** `docs/superpowers/specs/2026-09-23-elm327-full-emulation-design.md`（UI 画面案: https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa ）

## Global Constraints

- ELM の ID 文字列は `ELM327 v1.5`、`AT@1` は `OBDII to RS232 Interpreter`。
- CAN の送信パディングは ELM 側・ECU 側とも `0x00`。
- `AT ST` の初期値は `0x32`（×4ms = 200ms）。適応タイミング（AT1/AT2）の待ちは「最後の応答から min(ST, 50ms)」。
- ECU の基本遅延はエンジン 8ms、トランスミッション 15ms。応答保留は 1000ms 後に本応答、ELM 側は保留を受けたら 5000ms 待つ。
- ECU の ID: エンジン 7E0→7E8 / 18DA10F1→18DAF110、トランスミッション 7E1→7E9 / 18DA18F1→18DAF118。全 ECU 宛ては 7DF / 18DB33F1。トランスミッションは初期状態で無効。
- 開発用 TCP は `127.0.0.1:35000`、同時 1 接続。
- `lib/can`, `lib/ecu`, `lib/elm327`, `lib/vehicle`, `lib/util`, `lib/app/emulation_core.dart`, `lib/app/control_commands.dart`, `lib/transport/tcp_transport.dart` は `package:flutter` を import しない（`bin/` の CLI から使うため）。
- コメント・テスト名・UI 文言は日本語（既存コードに合わせる）。
- テストは `flutter test`、静的解析は `flutter analyze`。
- コミットメッセージは既存の形式（`feat: …` / `fix: …` / `test: …` / `docs: …`、本文は日本語）で、末尾に次の行を付ける:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## 設計書からの変更点（データシート・実クライアントで確かめた結果）

計画を書く際にデータシートと python-OBD のソースを読み直し、設計書と違う挙動が正しいと分かったものは計画側で直した。完了報告でもユーザーに伝える。

| # | 設計書 | 計画 | 根拠 |
|---|---|---|---|
| 1 | `iso_tp.dart` は `lib/elm327/` | `lib/can/iso_tp.dart` | ECU 側も使うため |
| 2 | CAF0 の送信上限は AL なら 8・NL なら 7 | CAF0 は常に 8 バイトまで | データシート p.45「CAF0 では AL を設定しなくても 8 バイト送れる」 |
| 3 | CAN 以外のプロトコル固定時は `UNABLE TO CONNECT` | 3〜5 は `BUS INIT: ...ERROR`、1・2・A〜C は `NO DATA` | p.24「固定プロトコルで接続できないと 'BUS INIT: ...ERROR' などを返し、ほかは試さない」。1・2・A〜C の文言は未確認 |
| 4 | `ATZ` / `ATD` でプロトコルも初期化 | `SP h` / `SP Ah` / `SP 00` で保存したプロトコルは Z・D 後も残る。`SP 0` と `TP` は保存しない | p.13（D は保存したプロトコルを読み戻す）、p.24（SP は保存、SP 0 は EEPROM に書かない、SP 00 は消す）、p.26（TP は保存しない） |
| 5 | D1 は常に DLC を表示 | D1 でも H1 のときだけ表示 | p.13「DLC を見るにはヘッダもオンである必要がある」 |
| 6 | Mode 06 は `46 MID` の後にテストが並ぶ | テスト 1 件ごとに `MID TID 単位 値 最小 最大` の 9 バイト | python-OBD の Mode 06 デコーダが 9 バイト単位で解釈するため（SAE J1979 本文は未確認） |
| 7 | python-OBD で複数 PID も確認 | 複数 PID は Dart のテストのみ | python-OBD は 1 回の問い合わせで 1 PID しか送らない |
| 8 | （記載なし） | 自動選択で未確定のときの `ATDPN` は `A0`、`ATDP` は `AUTO` | 未確認。python-OBD は 0100 の後に DPN を読むので影響しない |
| 9 | （記載なし） | 応答待ち・監視中に届いた LF（0x0A）と NUL（0x00）は `STOPPED` にしない | 未確認。CR LF を送るクライアントが毎回 `STOPPED` になるのを避けるため |
| 10 | 周期フレームは 11bit プロトコル中のみ流す | 常に 11bit で流し、29bit プロトコルのセッションは ID 種別の違いで表示しない | 見え方は同じで、バスがセッションのプロトコルを知らずに済む |
| 11 | `@3` は 12 文字を保存 | 2 回目以降の `@3` は `?` | p.26「@3 で一度設定した識別子は以後変更できない」 |

## 既存テストの期待値のうち変わるもの

Task 10 で旧テストを新 API に移すとき、次のものだけは期待値を変える（理由を完了報告に書く）。

| 旧テスト | 旧期待値 | 新期待値 | 理由 |
|---|---|---|---|
| ATZ（エコーあり） | `ATZ\rELM327 v1.5\r\r>` | `ATZ\r\r\rELM327 v1.5\r\r>` | 設計 §4（リセット後に空行 2 つ） |
| headers on | `7E8 04 41 0C 1A F8 ` | `7E8 04 41 0C 1A F8 00 00 00 ` | 設計 §7.1、データシート p.12・p.40 |
| 0100 ビットマップ | `41 00 18 1B 80 01 ` | `41 00 BE 3F A0 13 ` | 対応 PID が 38 個に増えた |
| ATDPN（起動直後） | `6` | `A0` | 起動直後は自動選択・未確定（変更点 8） |
| ATSP（引数なし） | `OK` | `?` | 設計 §5「パラメータ不正は ?」 |
| ATSP0 | protocol = 6 | 自動選択（protocol 0、DPN は確定後に `A6`） | 設計 §5 |
| 初期化前の未対応 PID | `SEARCHING...` + `NO DATA` | `SEARCHING...` + `UNABLE TO CONNECT` | 設計 §4（検索中に応答がなければ接続失敗） |
| LineAssembler「空行は捨てる」 | `[]` | `['']` | 設計 §4（空行で直前のコマンドを繰り返す） |
| 0902 VIN の 1 行目 | `0: ` の後に 7 バイト | `0: ` の後に 6 バイト | データシート p.44 の例（FF は 6 バイト） |

## Review Focus

仕様が明示していないが、使う人がまず踏む入力と期待される振る舞い。各行のテストは担当タスクに入れてある。

1. **CR LF を送るクライアント** — 応答待ちに LF が届いても `STOPPED` にならず、普通に応答が返る（Task 10 のテスト「LF は応答待ちを止めない」）。
2. **1 コマンドが複数回の BLE 書き込みに分かれて届く**（`01` と `0C\r`）— 1 つのコマンドとして処理される（Task 10「分割して届いたコマンドを 1 行として扱う」）。
3. **応答待ちの最中に UI で障害を切り替える**（ECU を無応答にする）— 例外にならず、その要求は `NO DATA` かデータで必ず終わる（Task 10「応答待ち中に障害を切り替えても必ず終わる」）。
4. **接続が切れた直後にタイマーが残っている** — 破棄したセッションは何も出力せず、例外も出さない（Task 10「dispose 後は出力しない」、Task 13 のコントローラのテスト「切断イベントでセッションを破棄する」）。
5. **UI の DTC 入力が小文字・前後の空白付き**（` p0420 `）— 大文字にして受け付け、形式違い（`X1`）はエラー表示で追加しない（Task 16 の DTC タブのテスト）。

## ファイル構成

| ファイル | 役割 | タスク |
|---|---|---|
| `lib/util/hex.dart` | 16 進の表示・解析 | 1 |
| `lib/can/can_frame.dart` | CAN フレーム | 1 |
| `lib/can/virtual_can_bus.dart` | 仮想バス（ノードへの配信・イベント購読） | 1 |
| `lib/can/iso_tp.dart` | ISO-TP の分割・種類判定・復元・FC | 2 |
| `lib/vehicle/vehicle_state.dart` | 車両の値（拡張） | 3 |
| `lib/ecu/dtc.dart` | DTC 文字列 ⇔ 2 バイト | 3 |
| `lib/ecu/ecu_profile.dart` | ECU ごとの ID・DTC・Mode 09 情報・DID 表 | 3 |
| `lib/ecu/pid_table.dart` | Mode 01 の PID 定義とビットマップ | 4 |
| `lib/ecu/obd_services.dart` | Mode 01/02/03/04/06/07/09/0A | 5 |
| `lib/ecu/uds_services.dart` | Mode 22 と否定応答 | 6 |
| `lib/can/fault_injector.dart` | 障害の設定と判定 | 6 |
| `lib/ecu/ecu.dart` | バス上の ECU（アドレス判定・遅延・ISO-TP 送信） | 6 |
| `lib/elm327/elm_state.dart` | AT 設定と実行時状態（作り直し） | 7 |
| `lib/elm327/line_assembler.dart` | バイト → 行（空行を通す） | 7 |
| `lib/elm327/response_formatter.dart` | 受信フレーム → 表示行 | 8 |
| `lib/elm327/at_commands.dart` | AT コマンドの表 | 9 |
| `lib/elm327/elm_session.dart` | 1 接続ぶんの ELM（非同期） | 10, 11 |
| `lib/can/periodic_traffic.dart` | ATMA 用の周期フレーム | 11 |
| `lib/vehicle/simulator.dart` | 派生値と積算（拡張） | 12 |
| `lib/app/emulation_core.dart` | 中核の組み立て（Flutter 非依存） | 13 |
| `lib/app/control_commands.dart` | CLI の制御コマンド | 13 |
| `lib/transport/tcp_transport.dart` | 開発用 TCP サーバ | 13 |
| `lib/transport/transport.dart` / `transport_bridge.dart` | tcp 追加・disconnect 追加 | 13, 14 |
| `lib/app/emulator_controller.dart` | Flutter 側の結線（作り直し） | 13 |
| `bin/elm327_tcp.dart` | UI なしの TCP エミュレータ | 13 |
| `android/.../BleGattServer.kt`, `SppServer.kt`, `Elm327Plugin.kt` | disconnect | 14 |
| `macos/Runner/BleGattServer.swift`, `Elm327Plugin.swift`, `Release.entitlements` | 疑似切断・TCP 許可 | 14 |
| `lib/ui/*.dart` | 6 タブ UI | 15, 16 |
| `tool/python_obd_check/check.py` | python-OBD 検証 | 17 |
| 削除: `lib/elm327/elm327_engine.dart`, `at_command_handler.dart`, `obd_command_handler.dart`, `obd_encoding.dart` と対応テスト | 旧エンジン | 13 |

---

### Task 1: 依存関係・16 進ヘルパ・CAN フレーム・仮想バス

**Files:**
- Modify: `pubspec.yaml`（dependencies に `clock`, `args`、dev_dependencies に `fake_async`）
- Create: `lib/util/hex.dart`, `lib/can/can_frame.dart`, `lib/can/virtual_can_bus.dart`
- Test: `test/util/hex_test.dart`, `test/can/virtual_can_bus_test.dart`

**Interfaces:**
- Consumes: なし
- Produces:
  - `String hex2(int v)`、`String hexN(int v, int width)`、`List<int>? parseHexBytes(String s)`
  - `class CanFrame { CanFrame(int id, List<int> data, {bool extended = false, bool rtr = false}); final int id; final bool extended; final bool rtr; final List<int> data; int get dlc; }`（`==` と `toString()` は `7E8 [2] 04 41` 形式）
  - `abstract class BusNode { void onFrame(CanFrame frame); }`
  - `class BusEvent { final CanFrame frame; final Object? sender; }`
  - `class VirtualCanBus { void attach(BusNode); void detach(BusNode); void Function() listen(void Function(BusEvent) onEvent); void transmit(CanFrame frame, {Object? sender}); }`
  - 配信は同期。`transmit` はまず全リスナーに、次に送信元以外の全ノードに配る。リスナーやノードの中から `transmit` を呼んでもよい（再入可）。

- [ ] **Step 1: 依存関係を追加する**

`pubspec.yaml` の `dependencies:` の `provider: ^6.1.0` の下に追加:

```yaml
  clock: ^1.1.2
  args: ^2.7.0
```

`dev_dependencies:` の `test: ^1.25.0` の下に追加:

```yaml
  fake_async: ^1.3.3
```

Run: `flutter pub get`
Expected: `Got dependencies!`（エラーなし）

- [ ] **Step 2: 失敗するテストを書く**

`test/util/hex_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/util/hex.dart';

void main() {
  test('hex2 は 2 桁の大文字', () {
    expect(hex2(0), '00');
    expect(hex2(0x1A), '1A');
    expect(hex2(0x1FF), 'FF');
  });

  test('hexN は指定桁で 0 埋め', () {
    expect(hexN(0x7E8, 3), '7E8');
    expect(hexN(0x14, 3), '014');
    expect(hexN(0x18DAF110, 8), '18DAF110');
  });

  test('parseHexBytes', () {
    expect(parseHexBytes('010C'), [0x01, 0x0C]);
    expect(parseHexBytes('ff'), [0xFF]);
    expect(parseHexBytes(''), isNull);
    expect(parseHexBytes('010'), isNull);
    expect(parseHexBytes('0XYZ'), isNull);
  });
}
```

`test/can/virtual_can_bus_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';

class _Recorder implements BusNode {
  final frames = <CanFrame>[];
  @override
  void onFrame(CanFrame frame) => frames.add(frame);
}

void main() {
  group('CanFrame', () {
    test('9 バイト以上は拒否', () {
      expect(() => CanFrame(0x7DF, List.filled(9, 0)), throwsArgumentError);
    });

    test('11bit で 0x800 以上は拒否、29bit は通る', () {
      expect(() => CanFrame(0x800, [0]), throwsArgumentError);
      expect(CanFrame(0x18DAF110, [0], extended: true).id, 0x18DAF110);
    });

    test('toString', () {
      expect(CanFrame(0x7E8, [0x04, 0x41]).toString(), '7E8 [2] 04 41');
      expect(CanFrame(0x18DAF110, [0x01], extended: true).toString(),
          '18DAF110 [1] 01');
    });

    test('== はデータまで比べる', () {
      expect(CanFrame(0x7E8, [1, 2]), CanFrame(0x7E8, [1, 2]));
      expect(CanFrame(0x7E8, [1, 2]) == CanFrame(0x7E8, [1, 3]), isFalse);
    });
  });

  group('VirtualCanBus', () {
    test('送信元以外のノードに配り、リスナーには全部流す', () {
      final bus = VirtualCanBus();
      final a = _Recorder();
      final b = _Recorder();
      bus
        ..attach(a)
        ..attach(b);
      final seen = <BusEvent>[];
      bus.listen(seen.add);
      final f = CanFrame(0x7DF, [0x02, 0x01, 0x0C]);
      bus.transmit(f, sender: a);
      expect(a.frames, isEmpty);
      expect(b.frames, [f]);
      expect(seen.single.frame, f);
      expect(seen.single.sender, same(a));
    });

    test('detach したノードと解除したリスナーには配らない', () {
      final bus = VirtualCanBus();
      final a = _Recorder();
      bus.attach(a);
      bus.detach(a);
      final seen = <BusEvent>[];
      final cancel = bus.listen(seen.add);
      cancel();
      bus.transmit(CanFrame(0x7DF, [0]));
      expect(a.frames, isEmpty);
      expect(seen, isEmpty);
    });

    test('リスナーの中から transmit しても配られる（再入）', () {
      final bus = VirtualCanBus();
      final node = _Recorder();
      bus.attach(node);
      bus.listen((e) {
        if (e.frame.id == 0x7E8) bus.transmit(CanFrame(0x7E0, [0x30]));
      });
      bus.transmit(CanFrame(0x7E8, [0x10]), sender: Object());
      expect(node.frames.map((f) => f.id), [0x7E0, 0x7E8]);
    });
  });
}
```

- [ ] **Step 3: 失敗を確認する**

Run: `flutter test test/util/hex_test.dart test/can/virtual_can_bus_test.dart`
Expected: FAIL（`Target of URI doesn't exist: 'package:elm327emu/util/hex.dart'` など）

- [ ] **Step 4: 実装する**

`lib/util/hex.dart`:

```dart
/// 16 進の表示と解析。
String hex2(int v) => (v & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0');

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
```

`lib/can/can_frame.dart`:

```dart
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
    final idText =
        id.toRadixString(16).toUpperCase().padLeft(extended ? 8 : 3, '0');
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
```

`lib/can/virtual_can_bus.dart`:

```dart
import 'can_frame.dart';

/// バスにつながる機器（ECU など）。
abstract class BusNode {
  void onFrame(CanFrame frame);
}

/// バスを流れたフレームと、その送信元。
class BusEvent {
  const BusEvent(this.frame, this.sender);
  final CanFrame frame;
  final Object? sender;
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

  void transmit(CanFrame frame, {Object? sender}) {
    final event = BusEvent(frame, sender);
    for (final l in List.of(_listeners)) {
      l(event);
    }
    for (final node in List.of(_nodes)) {
      if (!identical(node, sender)) node.onFrame(frame);
    }
  }
}
```

- [ ] **Step 5: 通ることを確認する**

Run: `flutter test test/util/hex_test.dart test/can/virtual_can_bus_test.dart`
Expected: PASS（全件）

- [ ] **Step 6: コミット**

```bash
git add pubspec.yaml pubspec.lock lib/util/hex.dart lib/can/can_frame.dart lib/can/virtual_can_bus.dart test/util/hex_test.dart test/can/virtual_can_bus_test.dart
git commit -m "feat: CANフレームと仮想CANバス、16進ヘルパ

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ISO-TP（分割・種類判定・復元・フロー制御）

**Files:**
- Create: `lib/can/iso_tp.dart`
- Test: `test/can/iso_tp_test.dart`

**Interfaces:**
- Consumes: なし
- Produces:
  - `const int canPadByte = 0x00;`
  - `List<List<int>> segment(List<int> payload, {bool pad = true})` — 7 バイト以下は SF 1 つ、それ超は FF（6 バイト）+ CF（7 バイトずつ、連番 1→F→0）。`pad` なら各フレームを 8 バイトに 0x00 で詰める。長さ 0 と 4096 以上は `ArgumentError`。
  - `List<int> flowControl({int blockSize = 0, int stMin = 0})` — `[0x30, bs, st, 0,0,0,0,0]`
  - `enum FrameType { single, first, consecutive, flowControl, invalid }` と `FrameType frameType(List<int> data)`
  - `class Reassembler { List<int>? add(List<int> data); bool get inProgress; }` — 完成したメッセージ（PCI・パディングを除いたペイロード）を返す。連番が飛んだら破棄。

- [ ] **Step 1: 失敗するテストを書く**

`test/can/iso_tp_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/can/iso_tp.dart';

final _vin = [0x49, 0x02, 0x01, ...'WAUZZZ8K9AA000000'.codeUnits];

void main() {
  group('segment', () {
    test('7 バイト以下は SF 1 つ（0x00 で 8 バイトに詰める）', () {
      expect(segment([0x41, 0x0C, 0x0C, 0x80]), [
        [0x04, 0x41, 0x0C, 0x0C, 0x80, 0x00, 0x00, 0x00],
      ]);
    });

    test('pad: false なら詰めない', () {
      expect(segment([0x44], pad: false), [
        [0x01, 0x44],
      ]);
    });

    test('VIN（20 バイト）は FF と CF 2 つ', () {
      expect(segment(_vin), [
        [0x10, 0x14, 0x49, 0x02, 0x01, 0x57, 0x41, 0x55],
        [0x21, 0x5A, 0x5A, 0x5A, 0x38, 0x4B, 0x39, 0x41],
        [0x22, 0x41, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30],
      ]);
    });

    test('連番は F の次に 0 へ戻る', () {
      final frames = segment(List.generate(6 + 7 * 16, (i) => i & 0xFF));
      expect(frames[15][0], 0x2F);
      expect(frames[16][0], 0x20);
    });

    test('空と 4096 バイト以上は拒否', () {
      expect(() => segment([]), throwsArgumentError);
      expect(() => segment(List.filled(4096, 0)), throwsArgumentError);
    });
  });

  test('frameType', () {
    expect(frameType([0x04, 0x41, 0x0C, 0x0C, 0x80, 0, 0, 0]),
        FrameType.single);
    expect(frameType([0x00, 0, 0]), FrameType.invalid);
    expect(frameType([0x08, 0, 0, 0, 0, 0, 0, 0]), FrameType.invalid);
    expect(frameType([0x03, 0x41]), FrameType.invalid); // 長さが足りない
    expect(frameType([0x10, 0x14, 0, 0, 0, 0, 0, 0]), FrameType.first);
    expect(frameType([0x21, 0, 0]), FrameType.consecutive);
    expect(frameType([0x30, 0, 0]), FrameType.flowControl);
    expect(frameType([0x40]), FrameType.invalid);
    expect(frameType([]), FrameType.invalid);
  });

  test('flowControl', () {
    expect(flowControl(), [0x30, 0, 0, 0, 0, 0, 0, 0]);
    expect(flowControl(blockSize: 2, stMin: 5).sublist(0, 3), [0x30, 2, 5]);
  });

  group('Reassembler', () {
    test('SF はパディングを除いて返す', () {
      expect(Reassembler().add([0x04, 0x41, 0x0C, 0x0C, 0x80, 0, 0, 0]),
          [0x41, 0x0C, 0x0C, 0x80]);
    });

    test('FF と CF から復元する', () {
      final r = Reassembler();
      final frames = segment(_vin);
      expect(r.add(frames[0]), isNull);
      expect(r.inProgress, isTrue);
      expect(r.add(frames[1]), isNull);
      expect(r.add(frames[2]), _vin);
      expect(r.inProgress, isFalse);
    });

    test('連番が飛んだら破棄する', () {
      final r = Reassembler();
      final frames = segment(_vin);
      r.add(frames[0]);
      expect(r.add(frames[2]), isNull);
      expect(r.inProgress, isFalse);
    });

    test('FF なしの CF は無視する', () {
      expect(Reassembler().add([0x21, 1, 2, 3, 4, 5, 6, 7]), isNull);
    });

    test('長さ 1〜300 の全長で segment → add が元に戻る', () {
      for (var n = 1; n <= 300; n++) {
        final payload = List.generate(n, (i) => (i * 7) & 0xFF);
        final r = Reassembler();
        List<int>? out;
        for (final f in segment(payload)) {
          out = r.add(f);
        }
        expect(out, payload, reason: 'length $n');
      }
    });
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/can/iso_tp_test.dart`
Expected: FAIL（`iso_tp.dart` がない）

- [ ] **Step 3: 実装する**

`lib/can/iso_tp.dart`:

```dart
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
    p([0x10 | (payload.length >> 8), payload.length & 0xFF, ...payload.sublist(0, 6)]),
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
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/can/iso_tp_test.dart`
Expected: PASS（全件）

- [ ] **Step 5: コミット**

```bash
git add lib/can/iso_tp.dart test/can/iso_tp_test.dart
git commit -m "feat: ISO-TP の分割・復元・フロー制御

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 車両状態の拡張・DTC 変換・ECU プロファイル

**Files:**
- Modify: `lib/vehicle/vehicle_state.dart`（全置き換え。旧エンジン用の `dtcs` と `vin` は Task 13 まで残す）
- Create: `lib/ecu/dtc.dart`, `lib/ecu/ecu_profile.dart`
- Test: `test/vehicle/vehicle_state_test.dart`, `test/ecu/dtc_test.dart`, `test/ecu/ecu_profile_test.dart`

**Interfaces:**
- Consumes: `hex2`（Task 1）
- Produces:
  - `VehicleState` のフィールド（すべて public・可変）: `int rpm`, `double speedKmh, coolantTempC, engineLoadPct, throttlePct, intakeTempC, maf, fuelLevelPct, batteryVoltage, stftPct, ltftPct, mapKpa, timingDeg, baroKpa, ambientTempC, oilTempC, fuelRateLph, catalystTempC, lambda, acceleratorPct, absLoadPct, runTimeSec, odometerKm, distanceSinceClearKm, distanceWithMilKm, secondsSinceClear, secondsWithMil`, `int warmupsSinceClear, readinessIncomplete`、旧用 `List<String> dtcs`, `String vin`。`VehicleState.defaults()`
  - `bool isValidDtc(String)`, `List<int> dtcToBytes(String)`, `String dtcFromBytes(int a, int b)`
  - `const functionalId11 = 0x7DF; const functionalId29 = 0x18DB33F1;`
  - `const Set<int> engineMode01Pids`（38 個）
  - `class DidValue { DidValue.ascii(String); DidValue.hex(List<int>); final bool isAscii; final List<int> bytes; String get display; }`
  - `class FreezeFrame { final String dtc; final Map<int, List<int>> pids; final DateTime capturedAt; }`
  - `class EcuProfile`（`name`, `label`, `requestId11`, `responseId11`, `address29`, `requestId29`, `responseId29For(int tester)`, `enabled`, `baseLatency`, `mode01Pids`, `confirmedDtcs`, `pendingDtcs`, `permanentDtcs`, `freezeFrame`, `vin`, `calid`, `cvn`, `ecuName`, `dids`, `mode09Pids`）と `EcuProfile.engine()`, `EcuProfile.transmission()`

- [ ] **Step 1: 失敗するテストを書く**

`test/vehicle/vehicle_state_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  test('既定値', () {
    final v = VehicleState.defaults();
    expect(v.rpm, 800);
    expect(v.speedKmh, 0);
    expect(v.coolantTempC, 85);
    expect(v.batteryVoltage, 12.4);
    expect(v.odometerKm, 48213.4);
    expect(v.readinessIncomplete, 0);
    expect(v.warmupsSinceClear, 0);
    expect(v.vin.length, 17);
    expect(v.dtcs, ['P0301']);
  });
}
```

`test/ecu/dtc_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/ecu/dtc.dart';

void main() {
  test('DTC 文字列 ⇔ 2 バイト', () {
    expect(dtcToBytes('P0301'), [0x03, 0x01]);
    expect(dtcToBytes('P0420'), [0x04, 0x20]);
    expect(dtcToBytes('U0100'), [0xC1, 0x00]);
    expect(dtcToBytes('C1234'), [0x52, 0x34]);
    expect(dtcFromBytes(0x03, 0x01), 'P0301');
    expect(dtcFromBytes(0xC1, 0x00), 'U0100');
  });

  test('isValidDtc', () {
    expect(isValidDtc('P0301'), isTrue);
    expect(isValidDtc('B3FFF'), isTrue);
    expect(isValidDtc('p0301'), isFalse);
    expect(isValidDtc('P4301'), isFalse);
    expect(isValidDtc('X0301'), isFalse);
    expect(isValidDtc('P030'), isFalse);
  });

  test('形式違いは dtcToBytes で例外', () {
    expect(() => dtcToBytes('X1'), throwsArgumentError);
  });
}
```

`test/ecu/ecu_profile_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';

void main() {
  test('エンジンの ID と既定値', () {
    final e = EcuProfile.engine();
    expect(e.name, 'engine');
    expect(e.enabled, isTrue);
    expect(e.requestId11, 0x7E0);
    expect(e.responseId11, 0x7E8);
    expect(e.requestId29, 0x18DA10F1);
    expect(e.responseId29For(0xF1), 0x18DAF110);
    expect(e.baseLatency, const Duration(milliseconds: 8));
    expect(e.mode01Pids.length, 38);
    expect(e.mode09Pids, {0x02, 0x04, 0x06, 0x0A});
    expect(e.confirmedDtcs, isEmpty);
    expect(e.calid.length, 16);
    expect(e.dids.keys, containsAll([0xF190, 0xF187, 0xF18C, 0xF191]));
  });

  test('トランスミッションは無効・PID は 01 と A4 のみ・VIN なし', () {
    final t = EcuProfile.transmission();
    expect(t.enabled, isFalse);
    expect(t.requestId11, 0x7E1);
    expect(t.responseId11, 0x7E9);
    expect(t.requestId29, 0x18DA18F1);
    expect(t.responseId29For(0xF1), 0x18DAF118);
    expect(t.baseLatency, const Duration(milliseconds: 15));
    expect(t.mode01Pids, {0x01, 0xA4});
    expect(t.mode09Pids, {0x04, 0x06, 0x0A});
  });

  test('DidValue', () {
    expect(DidValue.ascii('AB').bytes, [0x41, 0x42]);
    expect(DidValue.ascii('AB').display, 'AB');
    expect(DidValue.hex([0x0A, 0x1B]).display, '0A 1B');
    expect(() => DidValue.ascii('A\u0001'), throwsArgumentError);
    expect(() => DidValue.hex([]), throwsArgumentError);
  });

  test('エンジンの VIN を空にすると Mode 09 の 02 が消える', () {
    final e = EcuProfile.engine()..vin = '';
    expect(e.mode09Pids, {0x04, 0x06, 0x0A});
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/vehicle/vehicle_state_test.dart test/ecu/dtc_test.dart test/ecu/ecu_profile_test.dart`
Expected: FAIL（`odometerKm` 未定義、`dtc.dart` なし など）

- [ ] **Step 3: 実装する**

`lib/vehicle/vehicle_state.dart`（全置き換え）:

```dart
/// エミュレートする車両の現在状態。Simulator または UI が更新する。
class VehicleState {
  int rpm = 800;
  double speedKmh = 0;
  double coolantTempC = 85;
  double engineLoadPct = 20;
  double throttlePct = 12;
  double intakeTempC = 30;
  double maf = 3.5; // g/s
  double fuelLevelPct = 70;
  double batteryVoltage = 12.4;
  double stftPct = 1.6; // 短期燃料トリム B1
  double ltftPct = -0.8; // 長期燃料トリム B1
  double mapKpa = 33; // 吸気管圧力
  double timingDeg = 10; // 点火時期
  double baroKpa = 101;
  double ambientTempC = 22;
  double oilTempC = 90;
  double fuelRateLph = 0.8;
  double catalystTempC = 420;
  double lambda = 1.0;
  double acceleratorPct = 10;
  double absLoadPct = 18;
  double runTimeSec = 0; // エンジン始動後の経過時間
  double odometerKm = 48213.4;
  double distanceSinceClearKm = 0;
  double distanceWithMilKm = 0;
  double secondsSinceClear = 0;
  double secondsWithMil = 0;
  int warmupsSinceClear = 0;

  /// レディネスの未完了ビット（0101 の D バイト。ビットの意味は C バイトと同じ）。
  int readinessIncomplete = 0;

  // 旧エンジン（Elm327Engine）用。Task 13 で削除する。
  List<String> dtcs = ['P0301'];
  String vin = 'WAUZZZ8K9AA000000';

  VehicleState();

  factory VehicleState.defaults() => VehicleState();
}
```

`lib/ecu/dtc.dart`:

```dart
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
  final digits = [(a >> 4) & 0x03, a & 0x0F, (b >> 4) & 0x0F, b & 0x0F]
      .map((d) => d.toRadixString(16).toUpperCase())
      .join();
  return '$letter$digits';
}
```

`lib/ecu/ecu_profile.dart`:

```dart
import '../util/hex.dart';

/// 全 ECU 宛て（functional）の要求 ID。
const functionalId11 = 0x7DF;
const functionalId29 = 0x18DB33F1;

/// エンジン ECU が対応する Mode 01 の PID（ビットマップ PID を除く 38 個）。
const Set<int> engineMode01Pids = {
  0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, //
  0x0F, 0x10, 0x11, 0x13, 0x1C, 0x1F, 0x21, 0x2F, 0x30, 0x31,
  0x33, 0x3C, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49,
  0x4A, 0x4C, 0x4D, 0x4E, 0x51, 0x5C, 0x5E, 0xA6,
};

/// Mode 22 の DID の値。ASCII か 16 進のバイト列。
class DidValue {
  DidValue.ascii(String text)
      : isAscii = true,
        bytes = List.unmodifiable(text.codeUnits) {
    if (text.isEmpty || text.codeUnits.any((c) => c < 0x20 || c > 0x7E)) {
      throw ArgumentError.value(text, 'text', '表示可能な ASCII 1 文字以上');
    }
  }

  DidValue.hex(List<int> bytes)
      : isAscii = false,
        bytes = List.unmodifiable(bytes) {
    if (bytes.isEmpty || bytes.any((b) => b < 0 || b > 0xFF)) {
      throw ArgumentError.value(bytes, 'bytes', '1 バイト以上');
    }
  }

  final bool isAscii;
  final List<int> bytes;

  String get display =>
      isAscii ? String.fromCharCodes(bytes) : bytes.map(hex2).join(' ');
}

/// フリーズフレーム。確定 DTC を追加した時点の Mode 01 の値（PID → データバイト）。
class FreezeFrame {
  FreezeFrame(
      {required this.dtc,
      required Map<int, List<int>> pids,
      required this.capturedAt})
      : pids = Map.unmodifiable(pids);

  final String dtc;
  final Map<int, List<int>> pids;
  final DateTime capturedAt;
}

/// ECU 1 台ぶんの設定と状態。
class EcuProfile {
  EcuProfile({
    required this.name,
    required this.label,
    required this.requestId11,
    required this.address29,
    required this.enabled,
    required this.baseLatency,
    required Set<int> mode01Pids,
    required this.vin,
    required this.calid,
    required this.cvn,
    required this.ecuName,
    required Map<int, DidValue> dids,
  })  : mode01Pids = Set.unmodifiable(mode01Pids),
        dids = Map.of(dids);

  factory EcuProfile.engine() => EcuProfile(
        name: 'engine',
        label: 'エンジン',
        requestId11: 0x7E0,
        address29: 0x10,
        enabled: true,
        baseLatency: const Duration(milliseconds: 8),
        mode01Pids: engineMode01Pids,
        vin: 'WAUZZZ8K9AA000000',
        calid: '8K0907115B  0010',
        cvn: [0x1A, 0x2B, 0x3C, 0x4D],
        ecuName: 'ECM-EngineControl',
        dids: {
          0xF190: DidValue.ascii('WAUZZZ8K9AA000000'),
          0xF187: DidValue.ascii('8K0907115B'),
          0xF18C: DidValue.ascii('SN00123456'),
          0xF191: DidValue.hex([0x0A, 0x1B, 0x2C, 0x3D]),
        },
      );

  factory EcuProfile.transmission() => EcuProfile(
        name: 'transmission',
        label: 'トランスミッション',
        requestId11: 0x7E1,
        address29: 0x18,
        enabled: false,
        baseLatency: const Duration(milliseconds: 15),
        mode01Pids: {0x01, 0xA4},
        vin: '',
        calid: 'TCM0AW300000001',
        cvn: [0x5E, 0x6F, 0x70, 0x81],
        ecuName: 'TCM-TransmissionCtl',
        dids: {
          0xF187: DidValue.ascii('0AW300'),
          0xF18C: DidValue.ascii('SN00987654'),
        },
      );

  final String name;
  final String label;
  final int requestId11;
  final int address29;
  bool enabled;
  final Duration baseLatency;
  final Set<int> mode01Pids;
  final List<String> confirmedDtcs = [];
  final List<String> pendingDtcs = [];
  final List<String> permanentDtcs = [];
  FreezeFrame? freezeFrame;
  String vin;
  String calid;
  List<int> cvn;
  String ecuName;
  final Map<int, DidValue> dids;

  int get responseId11 => requestId11 + 8;

  /// テスター F1 からの物理アドレス要求 ID（18 DA <ECU> F1）。
  int get requestId29 => 0x18DA0000 | (address29 << 8) | 0xF1;

  /// テスター [tester] 宛ての応答 ID（18 DA <tester> <ECU>）。
  int responseId29For(int tester) =>
      0x18DA0000 | ((tester & 0xFF) << 8) | address29;

  Set<int> get mode09Pids => {if (vin.isNotEmpty) 0x02, 0x04, 0x06, 0x0A};
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/vehicle/vehicle_state_test.dart test/ecu/dtc_test.dart test/ecu/ecu_profile_test.dart && flutter test`
Expected: 新規分が PASS。全体も PASS（旧テストは `dtcs` と `vin` を残したので通る）

- [ ] **Step 5: コミット**

```bash
git add lib/vehicle/vehicle_state.dart lib/ecu/dtc.dart lib/ecu/ecu_profile.dart test/vehicle/vehicle_state_test.dart test/ecu/dtc_test.dart test/ecu/ecu_profile_test.dart
git commit -m "feat: 車両状態の拡張、DTC変換、ECUプロファイル

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Mode 01 の PID 表とビットマップ

**Files:**
- Create: `lib/ecu/pid_table.dart`
- Test: `test/ecu/pid_table_test.dart`

**Interfaces:**
- Consumes: `VehicleState`, `EcuProfile`, `engineMode01Pids`（Task 3）
- Produces:
  - `typedef PidEncoder = List<int> Function(VehicleState v, EcuProfile ecu);`
  - `class PidDef { final int pid; final String label; final PidEncoder encode; }`
  - `final Map<int, PidDef> pidTable`（エンジンの 38 個 + `0xA4`）
  - `int pct255(double pct)`, `int temp40(double c)`
  - `const readinessSupported = 0x65;`
  - `int gearFor(double speedKmh)`, `double gearRatioFor(double speedKmh)`
  - `bool isBitmapPid(int pid)`, `bool bitmapAvailable(int base, Set<int> supported)`, `List<int> supportBitmap(int base, Set<int> supported)`
  - `List<int>? mode01Data(int pid, VehicleState v, EcuProfile ecu)` — PID を含まないデータバイト。未対応は null。

- [ ] **Step 1: 失敗するテストを書く**

`test/ecu/pid_table_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/pid_table.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late VehicleState v;
  late EcuProfile engine;
  late EcuProfile tcm;
  setUp(() {
    v = VehicleState.defaults();
    engine = EcuProfile.engine();
    tcm = EcuProfile.transmission();
  });

  List<int>? d(int pid, [EcuProfile? e]) => mode01Data(pid, v, e ?? engine);

  test('全 PID に定義があり、空でないデータを返す', () {
    for (final pid in {...engineMode01Pids, 0xA4}) {
      expect(pidTable.containsKey(pid), isTrue, reason: hexPid(pid));
      final e = pid == 0xA4 ? tcm : engine;
      expect(pidTable[pid]!.encode(v, e), isNotEmpty, reason: hexPid(pid));
    }
  });

  group('エンコード（Wikipedia の式の逆）', () {
    test('0C 回転数', () {
      v.rpm = 1726;
      expect(d(0x0C), [0x1A, 0xF8]);
      v.rpm = 2150;
      expect(d(0x0C), [0x21, 0x98]);
    });
    test('05 水温 / 0F 吸気温 / 46 外気温 / 5C 油温 は +40', () {
      expect(d(0x05), [0x7D]); // 85 + 40
      v.intakeTempC = -40;
      expect(d(0x0F), [0x00]);
      v.ambientTempC = 22;
      expect(d(0x46), [0x3E]);
      v.oilTempC = 92;
      expect(d(0x5C), [0x84]);
    });
    test('04 負荷 / 11 スロットル / 2F 燃料 は ×255/100', () {
      v.engineLoadPct = 100;
      expect(d(0x04), [0xFF]);
      v.throttlePct = 50;
      expect(d(0x11), [0x80]);
      v.fuelLevelPct = 0;
      expect(d(0x2F), [0x00]);
    });
    test('06 燃料トリム: 1.6% → 0x82（130/1.28-100 = 1.56）', () {
      expect(d(0x06), [0x82]);
    });
    test('0E 点火時期: 12.5° → 0x99', () {
      v.timingDeg = 12.5;
      expect(d(0x0E), [0x99]);
    });
    test('10 MAF: 7.2 g/s → 0x02D0', () {
      v.maf = 7.2;
      expect(d(0x10), [0x02, 0xD0]);
    });
    test('1F 経過時間: 872 秒 → 0x0368', () {
      v.runTimeSec = 872;
      expect(d(0x1F), [0x03, 0x68]);
    });
    test('3C 触媒温度: 420°C → 0x11F8', () {
      expect(d(0x3C), [0x11, 0xF8]);
    });
    test('42 電圧: 12.4V → 0x3070', () {
      expect(d(0x42), [0x30, 0x70]);
    });
    test('44 λ: 1.0 → 0x8000', () {
      expect(d(0x44), [0x80, 0x00]);
    });
    test('5E 燃料消費率: 4.1 L/h → 0x0052', () {
      v.fuelRateLph = 4.1;
      expect(d(0x5E), [0x00, 0x52]);
    });
    test('A6 走行距離: 48213.4 km → 0x00075B56', () {
      expect(d(0xA6), [0x00, 0x07, 0x5B, 0x56]);
    });
    test('4D / 4E は分', () {
      v.secondsWithMil = 125;
      v.secondsSinceClear = 3600;
      expect(d(0x4D), [0x00, 0x02]);
      expect(d(0x4E), [0x00, 0x3C]);
    });
    test('値は範囲外でも飽和する', () {
      v.speedKmh = 400;
      expect(d(0x0D), [0xFF]);
      v.rpm = -5;
      expect(d(0x0C), [0x00, 0x00]);
    });
  });

  group('0101 モニタ状態', () {
    test('確定 DTC 1 件なら MIL 点灯・件数 1、レディネスは完了', () {
      engine.confirmedDtcs.add('P0301');
      expect(d(0x01), [0x81, 0x07, 0x65, 0x00]);
    });
    test('DTC なしなら A = 0、消去直後は D = C（全未完了）', () {
      v.readinessIncomplete = readinessSupported;
      expect(d(0x01), [0x00, 0x07, 0x65, 0x65]);
    });
    test('0141 の A は常に 0', () {
      engine.confirmedDtcs.add('P0301');
      expect(d(0x41)![0], 0x00);
    });
    test('トランスミッションは件数のみ', () {
      tcm.confirmedDtcs.addAll(['P0700', 'P0715']);
      expect(d(0x01, tcm), [0x82, 0x00, 0x00, 0x00]);
    });
  });

  test('A4 ギア: 62 km/h は 4 速・変速比 1.000', () {
    v.speedKmh = 62;
    expect(gearFor(62), 4);
    expect(d(0xA4, tcm), [0x02, 0x00, 0x03, 0xE8]);
    expect(gearFor(0), 1);
    expect(gearFor(120), 6);
  });

  group('ビットマップ（Python で計算した値と一致）', () {
    test('エンジン', () {
      expect(d(0x00), [0xBE, 0x3F, 0xA0, 0x13]);
      expect(d(0x20), [0x80, 0x03, 0xA0, 0x11]);
      expect(d(0x40), [0xFE, 0xDC, 0x80, 0x15]);
      expect(d(0x60), [0x00, 0x00, 0x00, 0x01]);
      expect(d(0x80), [0x00, 0x00, 0x00, 0x01]);
      expect(d(0xA0), [0x04, 0x00, 0x00, 0x00]);
      expect(d(0xC0), isNull);
    });
    test('トランスミッション', () {
      expect(d(0x00, tcm), [0x80, 0x00, 0x00, 0x01]);
      expect(d(0xA0, tcm), [0x10, 0x00, 0x00, 0x00]);
    });
  });

  test('未対応 PID は null', () {
    expect(d(0xFF), isNull);
    expect(d(0x0C, tcm), isNull);
    expect(d(0xA4), isNull);
  });
}

String hexPid(int pid) => pid.toRadixString(16);
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/ecu/pid_table_test.dart`
Expected: FAIL（`pid_table.dart` がない）

- [ ] **Step 3: 実装する**

`lib/ecu/pid_table.dart`:

```dart
import '../vehicle/vehicle_state.dart';
import 'ecu_profile.dart';

/// Mode 01 の PID 定義。式は Wikipedia「OBD-II PIDs」の Service 01 表の逆。
typedef PidEncoder = List<int> Function(VehicleState v, EcuProfile ecu);

class PidDef {
  const PidDef(this.pid, this.label, this.encode);
  final int pid;
  final String label;
  final PidEncoder encode;
}

int _clamp(num v, int lo, int hi) => v.round().clamp(lo, hi).toInt();

int pct255(double pct) => _clamp(pct.clamp(0, 100) * 255 / 100, 0, 255);
int temp40(double c) => _clamp(c + 40, 0, 255);
int _trim(double pct) => _clamp((pct + 100) * 128 / 100, 0, 255);
List<int> _u8(num v) => [_clamp(v, 0, 255)];
List<int> _u16(num v) {
  final x = _clamp(v, 0, 0xFFFF);
  return [x >> 8, x & 0xFF];
}

List<int> _u32(num v) {
  final x = _clamp(v, 0, 0xFFFFFFFF);
  return [(x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF];
}

/// 0101 の C バイト（対応している火花点火車のテスト）: 触媒・EVAP・O2・O2 ヒーター。
const readinessSupported = 0x65;

List<int> _monitorStatus(VehicleState v, EcuProfile e, {required bool sinceClear}) {
  final count = e.confirmedDtcs.length.clamp(0, 0x7F).toInt();
  final a = sinceClear ? ((e.confirmedDtcs.isEmpty ? 0 : 0x80) | count) : 0x00;
  if (e.name != 'engine') return [a, 0x00, 0x00, 0x00];
  // B: 共通テスト（ミスファイア・燃料系・コンポーネント）が対応済みかつ完了、火花点火。
  return [a, 0x07, readinessSupported, v.readinessIncomplete & readinessSupported];
}

const _gearRatios = [3.5, 2.1, 1.4, 1.0, 0.8, 0.65];

int gearFor(double speedKmh) {
  if (speedKmh < 20) return 1;
  if (speedKmh < 40) return 2;
  if (speedKmh < 60) return 3;
  if (speedKmh < 80) return 4;
  if (speedKmh < 100) return 5;
  return 6;
}

double gearRatioFor(double speedKmh) => _gearRatios[gearFor(speedKmh) - 1];

final List<PidDef> _defs = [
  PidDef(0x01, 'モニタ状態', (v, e) => _monitorStatus(v, e, sinceClear: true)),
  PidDef(0x03, '燃料系の状態', (v, e) => [0x02, 0x00]),
  PidDef(0x04, 'エンジン負荷', (v, e) => [pct255(v.engineLoadPct)]),
  PidDef(0x05, '水温', (v, e) => [temp40(v.coolantTempC)]),
  PidDef(0x06, '短期燃料トリム B1', (v, e) => [_trim(v.stftPct)]),
  PidDef(0x07, '長期燃料トリム B1', (v, e) => [_trim(v.ltftPct)]),
  PidDef(0x0B, '吸気管圧力', (v, e) => _u8(v.mapKpa)),
  PidDef(0x0C, '回転数', (v, e) => _u16(v.rpm * 4)),
  PidDef(0x0D, '車速', (v, e) => _u8(v.speedKmh)),
  PidDef(0x0E, '点火時期', (v, e) => _u8((v.timingDeg + 64) * 2)),
  PidDef(0x0F, '吸気温', (v, e) => [temp40(v.intakeTempC)]),
  PidDef(0x10, '空気流量 MAF', (v, e) => _u16(v.maf * 100)),
  PidDef(0x11, 'スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x13, 'O2 センサの有無', (v, e) => [0x03]),
  PidDef(0x1C, 'OBD 規格', (v, e) => [0x06]),
  PidDef(0x1F, '始動後の経過時間', (v, e) => _u16(v.runTimeSec)),
  PidDef(0x21, 'MIL 点灯後の距離', (v, e) => _u16(v.distanceWithMilKm)),
  PidDef(0x2F, '燃料残量', (v, e) => [pct255(v.fuelLevelPct)]),
  PidDef(0x30, '消去後のウォームアップ回数', (v, e) => _u8(v.warmupsSinceClear)),
  PidDef(0x31, '消去後の距離', (v, e) => _u16(v.distanceSinceClearKm)),
  PidDef(0x33, '大気圧', (v, e) => _u8(v.baroKpa)),
  PidDef(0x3C, '触媒温度 B1S1', (v, e) => _u16((v.catalystTempC + 40) * 10)),
  PidDef(0x41, '今回サイクルのモニタ状態', (v, e) => _monitorStatus(v, e, sinceClear: false)),
  PidDef(0x42, '制御モジュール電圧', (v, e) => _u16(v.batteryVoltage * 1000)),
  PidDef(0x43, '絶対負荷', (v, e) => _u16(v.absLoadPct * 255 / 100)),
  PidDef(0x44, '指令空燃比', (v, e) => _u16(v.lambda * 32768)),
  PidDef(0x45, '相対スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x46, '外気温', (v, e) => [temp40(v.ambientTempC)]),
  PidDef(0x47, '絶対スロットル B', (v, e) => [pct255(v.throttlePct * 0.9 + 8)]),
  PidDef(0x49, 'アクセル開度 D', (v, e) => [pct255(v.acceleratorPct)]),
  PidDef(0x4A, 'アクセル開度 E', (v, e) => [pct255(v.acceleratorPct * 0.5)]),
  PidDef(0x4C, '指令スロットル', (v, e) => [pct255(v.throttlePct)]),
  PidDef(0x4D, 'MIL 点灯時間', (v, e) => _u16(v.secondsWithMil / 60)),
  PidDef(0x4E, '消去後の時間', (v, e) => _u16(v.secondsSinceClear / 60)),
  PidDef(0x51, '燃料の種類', (v, e) => [0x01]),
  PidDef(0x5C, '油温', (v, e) => [temp40(v.oilTempC)]),
  PidDef(0x5E, '燃料消費率', (v, e) => _u16(v.fuelRateLph * 20)),
  PidDef(0xA4, '実ギア', (v, e) => [0x02, 0x00, ..._u16(gearRatioFor(v.speedKmh) * 1000)]),
  PidDef(0xA6, '走行距離計', (v, e) => _u32(v.odometerKm * 10)),
];

final Map<int, PidDef> pidTable = {for (final d in _defs) d.pid: d};

bool isBitmapPid(int pid) => pid % 0x20 == 0;

/// ビットマップ PID [base] に ECU が応答するか（base 0 は常に、ほかは base より上の PID があるとき）。
bool bitmapAvailable(int base, Set<int> supported) =>
    base == 0 || supported.any((p) => p > base);

/// [base]+1〜[base]+0x20 のサポートビットマップ 4 バイト。末尾ビットは次の範囲に PID があれば立つ。
List<int> supportBitmap(int base, Set<int> supported) {
  final out = [0, 0, 0, 0];
  for (var i = 0; i < 32; i++) {
    final pid = base + 1 + i;
    final on = supported.contains(pid) ||
        (pid == base + 0x20 && supported.any((p) => p > base + 0x20));
    if (on) out[i ~/ 8] |= 0x80 >> (i % 8);
  }
  return out;
}

/// ECU が Mode 01 の [pid] に返すデータ（PID を含まない）。未対応は null。
List<int>? mode01Data(int pid, VehicleState v, EcuProfile ecu) {
  if (isBitmapPid(pid)) {
    return bitmapAvailable(pid, ecu.mode01Pids)
        ? supportBitmap(pid, ecu.mode01Pids)
        : null;
  }
  if (!ecu.mode01Pids.contains(pid)) return null;
  return pidTable[pid]!.encode(v, ecu);
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/ecu/pid_table_test.dart`
Expected: PASS（全件）

- [ ] **Step 5: コミット**

```bash
git add lib/ecu/pid_table.dart test/ecu/pid_table_test.dart
git commit -m "feat: Mode 01 の PID 表（38項目）とサポートビットマップ

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: OBD サービス（Mode 01/02/03/04/06/07/09/0A）

**Files:**
- Create: `lib/ecu/obd_services.dart`
- Test: `test/ecu/obd_services_test.dart`

**Interfaces:**
- Consumes: `VehicleState`, `EcuProfile`, `FreezeFrame`, `dtcToBytes`, `isValidDtc`（Task 3）、`mode01Data`, `pidTable`, `supportBitmap`, `bitmapAvailable`, `isBitmapPid`, `readinessSupported`（Task 4）、`package:clock`
- Produces:
  - `class ObdServices { ObdServices(VehicleState vehicle); List<int>? handle(List<int> request, EcuProfile ecu); void addConfirmedDtc(EcuProfile ecu, String code); void clearDtcs(EcuProfile ecu); }`
  - `handle` は SID から始まる要求ペイロードを受け、応答ペイロード（SID+0x40 から）か null（無応答）を返す。対象は SID 0x01〜0x0A（05, 08 は null）。

- [ ] **Step 1: 失敗するテストを書く**

`test/ecu/obd_services_test.dart`:

```dart
import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/pid_table.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late VehicleState v;
  late EcuProfile engine;
  late EcuProfile tcm;
  late ObdServices obd;
  setUp(() {
    v = VehicleState.defaults();
    engine = EcuProfile.engine();
    tcm = EcuProfile.transmission();
    obd = ObdServices(v);
  });

  group('Mode 01', () {
    test('単一 PID', () {
      expect(obd.handle([0x01, 0x0C], engine), [0x41, 0x0C, 0x0C, 0x80]);
    });
    test('複数 PID は対応分だけ順に並べる', () {
      expect(obd.handle([0x01, 0x0C, 0x0D, 0x05], engine),
          [0x41, 0x0C, 0x0C, 0x80, 0x0D, 0x00, 0x05, 0x7D]);
      expect(obd.handle([0x01, 0x0C, 0xFF], engine), [0x41, 0x0C, 0x0C, 0x80]);
    });
    test('対応 PID がなければ null', () {
      expect(obd.handle([0x01, 0xFF], engine), isNull);
      expect(obd.handle([0x01], engine), isNull);
    });
  });

  group('Mode 03 / 07 / 0A', () {
    test('03 は確定 DTC、0 件は 43 00', () {
      expect(obd.handle([0x03], engine), [0x43, 0x00]);
      obd.addConfirmedDtc(engine, 'P0301');
      expect(obd.handle([0x03], engine), [0x43, 0x01, 0x03, 0x01]);
    });
    test('07 は保留、0A は永続', () {
      engine.pendingDtcs.add('P0171');
      engine.permanentDtcs.add('P0301');
      expect(obd.handle([0x07], engine), [0x47, 0x01, 0x01, 0x71]);
      expect(obd.handle([0x0A], engine), [0x4A, 0x01, 0x03, 0x01]);
    });
    test('3 件は 8 バイト（複数フレームになる長さ）', () {
      for (final c in ['P0301', 'P0302', 'P0420']) {
        obd.addConfirmedDtc(engine, c);
      }
      expect(obd.handle([0x03], engine)!.length, 8);
    });
  });

  group('Mode 04', () {
    test('確定・保留・フリーズフレームを消し、永続は残す', () {
      obd.addConfirmedDtc(engine, 'P0301');
      engine.pendingDtcs.add('P0171');
      engine.permanentDtcs.add('P0301');
      v
        ..distanceSinceClearKm = 12
        ..distanceWithMilKm = 5
        ..secondsSinceClear = 100
        ..secondsWithMil = 50
        ..warmupsSinceClear = 3;
      expect(obd.handle([0x04], engine), [0x44]);
      expect(engine.confirmedDtcs, isEmpty);
      expect(engine.pendingDtcs, isEmpty);
      expect(engine.permanentDtcs, ['P0301']);
      expect(engine.freezeFrame, isNull);
      expect(v.distanceSinceClearKm, 0);
      expect(v.distanceWithMilKm, 0);
      expect(v.secondsSinceClear, 0);
      expect(v.secondsWithMil, 0);
      expect(v.warmupsSinceClear, 0);
      expect(v.readinessIncomplete, readinessSupported);
    });
    test('トランスミッションの消去は車両の積算値に触れない', () {
      v.distanceSinceClearKm = 12;
      tcm.confirmedDtcs.add('P0700');
      expect(obd.handle([0x04], tcm), [0x44]);
      expect(tcm.confirmedDtcs, isEmpty);
      expect(v.distanceSinceClearKm, 12);
    });
  });

  group('Mode 02 フリーズフレーム', () {
    test('保存前は無応答', () {
      expect(obd.handle([0x02, 0x0C, 0x00], engine), isNull);
    });
    test('確定 DTC を追加した瞬間の値を返す', () {
      final at = DateTime(2026, 9, 23, 14, 2, 11);
      withClock(Clock.fixed(at), () {
        v.rpm = 2480;
        obd.addConfirmedDtc(engine, 'P0420');
      });
      v.rpm = 900;
      expect(engine.freezeFrame!.capturedAt, at);
      expect(obd.handle([0x02, 0x0C, 0x00], engine), [0x42, 0x0C, 0x00, 0x26, 0xC0]);
      expect(obd.handle([0x02, 0x02, 0x00], engine), [0x42, 0x02, 0x00, 0x04, 0x20]);
      expect(obd.handle([0x02, 0x00, 0x00], engine),
          [0x42, 0x00, 0x00, 0x7E, 0x3F, 0xA0, 0x13]);
    });
    test('2 件目の DTC では上書きしない', () {
      obd.addConfirmedDtc(engine, 'P0420');
      obd.addConfirmedDtc(engine, 'P0301');
      expect(engine.freezeFrame!.dtc, 'P0420');
    });
    test('フレーム番号 00 以外と形式違いは無応答', () {
      obd.addConfirmedDtc(engine, 'P0420');
      expect(obd.handle([0x02, 0x0C, 0x01], engine), isNull);
      expect(obd.handle([0x02, 0x0C], engine), isNull);
    });
  });

  test('addConfirmedDtc は形式違いで例外、重複は無視', () {
    expect(() => obd.addConfirmedDtc(engine, 'X1'), throwsArgumentError);
    obd.addConfirmedDtc(engine, 'P0301');
    obd.addConfirmedDtc(engine, 'P0301');
    expect(engine.confirmedDtcs, ['P0301']);
  });

  group('Mode 06', () {
    test('06 00 はサポート MID ビットマップ', () {
      expect(obd.handle([0x06, 0x00], engine), [0x46, 0x00, 0x80, 0x00, 0x00, 0x01]);
    });
    test('06 A2 は 9 バイト × 2 テスト', () {
      final r = obd.handle([0x06, 0xA2], engine)!;
      expect(r[0], 0x46);
      expect(r.length, 1 + 9 * 2);
      expect(r.sublist(1, 10), [0xA2, 0x0B, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]);
    });
    test('未対応 MID は無応答', () {
      expect(obd.handle([0x06, 0x02], engine), isNull);
    });
  });

  group('Mode 09', () {
    test('09 00 のビットマップ', () {
      expect(obd.handle([0x09, 0x00], engine), [0x49, 0x00, 0x54, 0x40, 0x00, 0x00]);
      expect(obd.handle([0x09, 0x00], tcm), [0x49, 0x00, 0x14, 0x40, 0x00, 0x00]);
    });
    test('09 02 VIN', () {
      expect(obd.handle([0x09, 0x02], engine),
          [0x49, 0x02, 0x01, ...'WAUZZZ8K9AA000000'.codeUnits]);
      expect(obd.handle([0x09, 0x02], tcm), isNull);
    });
    test('09 04 CALID は 16 バイト、09 0A ECU 名は 20 バイト（00 で詰める）', () {
      expect(obd.handle([0x09, 0x04], engine)!.length, 3 + 16);
      final name = obd.handle([0x09, 0x0A], engine)!;
      expect(name.length, 3 + 20);
      expect(name.sublist(3, 20), 'ECM-EngineControl'.codeUnits);
      expect(name.sublist(20), [0, 0, 0]);
    });
    test('09 06 CVN', () {
      expect(obd.handle([0x09, 0x06], engine), [0x49, 0x06, 0x01, 0x1A, 0x2B, 0x3C, 0x4D]);
    });
  });

  test('05 / 08 / 範囲外 SID は無応答', () {
    expect(obd.handle([0x05, 0x00], engine), isNull);
    expect(obd.handle([0x08, 0x00], engine), isNull);
    expect(obd.handle([0x22, 0xF1, 0x90], engine), isNull);
    expect(obd.handle([], engine), isNull);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/ecu/obd_services_test.dart`
Expected: FAIL（`obd_services.dart` がない）

- [ ] **Step 3: 実装する**

`lib/ecu/obd_services.dart`:

```dart
import 'package:clock/clock.dart';

import '../vehicle/vehicle_state.dart';
import 'dtc.dart';
import 'ecu_profile.dart';
import 'pid_table.dart';

/// Mode 06 のテスト 1 件。CAN 形式では MID TID 単位 値(2) 最小(2) 最大(2) の 9 バイト。
class _MonitorTest {
  const _MonitorTest(this.tid, this.unit, this.value, this.min, this.max);
  final int tid;
  final int unit;
  final int value;
  final int min;
  final int max;
}

/// 値は合格範囲内の固定値。TID・単位 ID の意味は SAE J1979 と照合していない。
const Map<int, List<_MonitorTest>> _mode06 = {
  0x01: [
    _MonitorTest(0x80, 0x0B, 0x0158, 0x0100, 0x0200),
    _MonitorTest(0x81, 0x0B, 0x0098, 0x0000, 0x00C8),
  ],
  0x21: [
    _MonitorTest(0x80, 0x24, 0x0012, 0x0000, 0x0040),
  ],
  0xA2: [
    _MonitorTest(0x0B, 0x24, 0x0000, 0x0000, 0x0002),
    _MonitorTest(0x0C, 0x24, 0x0001, 0x0000, 0x0002),
  ],
};

List<int> _padAscii(String s, int length) {
  final bytes = s.codeUnits.take(length).toList();
  return [...bytes, ...List.filled(length - bytes.length, 0)];
}

/// OBD-II の標準サービス（Mode 01〜0A）。
class ObdServices {
  ObdServices(this.vehicle);
  final VehicleState vehicle;

  /// SID から始まる要求 → 応答ペイロード。応答しないときは null。
  List<int>? handle(List<int> request, EcuProfile ecu) {
    if (request.isEmpty) return null;
    switch (request[0]) {
      case 0x01:
        return _mode01(request, ecu);
      case 0x02:
        return _mode02(request, ecu);
      case 0x03:
        return request.length == 1 ? _dtcList(0x43, ecu.confirmedDtcs) : null;
      case 0x04:
        if (request.length != 1) return null;
        clearDtcs(ecu);
        return [0x44];
      case 0x06:
        return _mode06Response(request);
      case 0x07:
        return request.length == 1 ? _dtcList(0x47, ecu.pendingDtcs) : null;
      case 0x09:
        return _mode09(request, ecu);
      case 0x0A:
        return request.length == 1 ? _dtcList(0x4A, ecu.permanentDtcs) : null;
      default:
        return null;
    }
  }

  /// 確定 DTC を追加する。最初の 1 件のとき、その時点の Mode 01 の値をフリーズフレームとして保存する。
  void addConfirmedDtc(EcuProfile ecu, String code) {
    if (!isValidDtc(code)) {
      throw ArgumentError.value(code, 'code', 'DTC の形式ではない');
    }
    if (ecu.confirmedDtcs.contains(code)) return;
    ecu.confirmedDtcs.add(code);
    ecu.freezeFrame ??= FreezeFrame(
      dtc: code,
      capturedAt: clock.now(),
      pids: {
        for (final pid in ecu.mode01Pids)
          if (pid != 0x01 && pid != 0x41) pid: pidTable[pid]!.encode(vehicle, ecu),
      },
    );
  }

  /// Mode 04 と同じ消去。永続 DTC は残す。
  void clearDtcs(EcuProfile ecu) {
    ecu.confirmedDtcs.clear();
    ecu.pendingDtcs.clear();
    ecu.freezeFrame = null;
    if (ecu.name != 'engine') return;
    vehicle
      ..distanceSinceClearKm = 0
      ..distanceWithMilKm = 0
      ..secondsSinceClear = 0
      ..secondsWithMil = 0
      ..warmupsSinceClear = 0
      ..readinessIncomplete = readinessSupported;
  }

  List<int>? _mode01(List<int> request, EcuProfile ecu) {
    if (request.length < 2) return null;
    final out = <int>[0x41];
    for (final pid in request.sublist(1)) {
      final data = mode01Data(pid, vehicle, ecu);
      if (data != null) out..add(pid)..addAll(data);
    }
    return out.length == 1 ? null : out;
  }

  List<int>? _mode02(List<int> request, EcuProfile ecu) {
    if (request.length != 3 || request[2] != 0x00) return null;
    final ff = ecu.freezeFrame;
    if (ff == null) return null;
    final pid = request[1];
    final stored = {...ff.pids.keys, 0x02};
    List<int>? data;
    if (isBitmapPid(pid)) {
      data = bitmapAvailable(pid, stored) ? supportBitmap(pid, stored) : null;
    } else if (pid == 0x02) {
      data = dtcToBytes(ff.dtc);
    } else {
      data = ff.pids[pid];
    }
    return data == null ? null : [0x42, pid, 0x00, ...data];
  }

  List<int> _dtcList(int sid, List<String> codes) => [
        sid,
        codes.length,
        for (final c in codes) ...dtcToBytes(c),
      ];

  List<int>? _mode06Response(List<int> request) {
    if (request.length != 2) return null;
    final mid = request[1];
    final mids = _mode06.keys.toSet();
    if (isBitmapPid(mid)) {
      return bitmapAvailable(mid, mids) ? [0x46, mid, ...supportBitmap(mid, mids)] : null;
    }
    final tests = _mode06[mid];
    if (tests == null) return null;
    return [
      0x46,
      for (final t in tests) ...[
        mid, t.tid, t.unit, //
        t.value >> 8, t.value & 0xFF,
        t.min >> 8, t.min & 0xFF,
        t.max >> 8, t.max & 0xFF,
      ],
    ];
  }

  List<int>? _mode09(List<int> request, EcuProfile ecu) {
    if (request.length != 2) return null;
    final pid = request[1];
    final supported = ecu.mode09Pids;
    if (pid == 0x00) return [0x49, 0x00, ...supportBitmap(0, supported)];
    if (!supported.contains(pid)) return null;
    switch (pid) {
      case 0x02:
        return [0x49, 0x02, 0x01, ...ecu.vin.codeUnits];
      case 0x04:
        return [0x49, 0x04, 0x01, ..._padAscii(ecu.calid, 16)];
      case 0x06:
        return [0x49, 0x06, 0x01, ...ecu.cvn];
      case 0x0A:
        return [0x49, 0x0A, 0x01, ..._padAscii(ecu.ecuName, 20)];
      default:
        return null;
    }
  }
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/ecu/obd_services_test.dart`
Expected: PASS（全件）

- [ ] **Step 5: コミット**

```bash
git add lib/ecu/obd_services.dart test/ecu/obd_services_test.dart
git commit -m "feat: OBD サービス（Mode 01/02/03/04/06/07/09/0A）とフリーズフレーム

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Mode 22・障害設定・バス上の ECU

**Files:**
- Create: `lib/ecu/uds_services.dart`, `lib/can/fault_injector.dart`, `lib/ecu/ecu.dart`
- Test: `test/ecu/uds_services_test.dart`, `test/can/fault_injector_test.dart`, `test/ecu/ecu_test.dart`

**Interfaces:**
- Consumes: `CanFrame`, `BusNode`, `VirtualCanBus`（Task 1）、`segment`, `frameType`, `FrameType`（Task 2）、`EcuProfile`, `functionalId11`（Task 3）、`ObdServices`（Task 5）
- Produces:
  - `class UdsServices { List<int>? handle(List<int> request, EcuProfile ecu, {required bool functional}); }`
  - `enum ElmErrorKind { canError, busError, busBusy, bufferFull, dataError, dataErrorMark, rxErrorMark, fbError, err94, lvReset, actAlert }`（`text`, `isMark`, `resetsState`）
  - `enum ErrorTrigger { once, always }`
  - `class FaultConfig { bool ignitionOff; Set<String> silentEcus; int delayMs; int dropPercent; bool responsePending; bool truncateMultiFrame; ElmErrorKind? error; ErrorTrigger errorTrigger; bool errorArmed; }`
  - `class FaultInjector { FaultInjector(FaultConfig config, {Random? random}); bool isSilent(EcuProfile); Duration get extraDelay; bool rollDrop(); ElmErrorKind? takeError(); }`
  - `class Ecu implements BusNode { Ecu({required EcuProfile profile, required VirtualCanBus bus, required ObdServices obd, required UdsServices uds, required FaultInjector faults}); void dispose(); static const flowControlTimeout, pendingDelay; }` — 生成しただけではバスにつながない（呼び出し側が `bus.attach`）。

- [ ] **Step 1: 失敗するテストを書く**

`test/ecu/uds_services_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/uds_services.dart';

void main() {
  final uds = UdsServices();
  final engine = EcuProfile.engine();

  test('22 F190 は 62 F1 90 + VIN', () {
    expect(uds.handle([0x22, 0xF1, 0x90], engine, functional: false),
        [0x62, 0xF1, 0x90, ...'WAUZZZ8K9AA000000'.codeUnits]);
  });
  test('22 F191 は HEX の値', () {
    expect(uds.handle([0x22, 0xF1, 0x91], engine, functional: false),
        [0x62, 0xF1, 0x91, 0x0A, 0x1B, 0x2C, 0x3D]);
  });
  test('表にない DID は 7F 22 31、長さ違いは 7F 22 13', () {
    expect(uds.handle([0x22, 0x12, 0x34], engine, functional: false), [0x7F, 0x22, 0x31]);
    expect(uds.handle([0x22, 0xF1], engine, functional: false), [0x7F, 0x22, 0x13]);
    expect(uds.handle([0x22, 0xF1, 0x90, 0xF1, 0x87], engine, functional: false),
        [0x7F, 0x22, 0x13]);
  });
  test('未対応サービスは ECU 指定なら 7F SID 11、全 ECU 宛てなら無応答', () {
    expect(uds.handle([0x10, 0x03], engine, functional: false), [0x7F, 0x10, 0x11]);
    expect(uds.handle([0x27, 0x01], engine, functional: false), [0x7F, 0x27, 0x11]);
    expect(uds.handle([0x10, 0x03], engine, functional: true), isNull);
  });
  test('全 ECU 宛ての 22 は無応答', () {
    expect(uds.handle([0x22, 0xF1, 0x90], engine, functional: true), isNull);
  });
}
```

`test/can/fault_injector_test.dart`:

```dart
import 'dart:math';
import 'package:test/test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';

void main() {
  test('ElmErrorKind の文言と分類', () {
    expect(ElmErrorKind.canError.text, 'CAN ERROR');
    expect(ElmErrorKind.dataErrorMark.text, '<DATA ERROR');
    expect(ElmErrorKind.rxErrorMark.isMark, isTrue);
    expect(ElmErrorKind.canError.isMark, isFalse);
    expect(ElmErrorKind.lvReset.resetsState, isTrue);
    expect(ElmErrorKind.err94.resetsState, isTrue);
    expect(ElmErrorKind.busError.resetsState, isFalse);
  });

  test('isSilent はイグニッション OFF か ECU 指定', () {
    final cfg = FaultConfig();
    final f = FaultInjector(cfg);
    final e = EcuProfile.engine();
    expect(f.isSilent(e), isFalse);
    cfg.silentEcus.add('engine');
    expect(f.isSilent(e), isTrue);
    cfg.silentEcus.clear();
    cfg.ignitionOff = true;
    expect(f.isSilent(e), isTrue);
  });

  test('rollDrop: 0% は常に false、100% は常に true', () {
    final cfg = FaultConfig();
    final f = FaultInjector(cfg, random: Random(1));
    expect(List.generate(50, (_) => f.rollDrop()).any((x) => x), isFalse);
    cfg.dropPercent = 100;
    expect(List.generate(50, (_) => f.rollDrop()).every((x) => x), isTrue);
  });

  test('takeError: once は 1 回で解除、always は解除しない、未発火は null', () {
    final cfg = FaultConfig()..error = ElmErrorKind.canError;
    final f = FaultInjector(cfg);
    expect(f.takeError(), isNull);
    cfg.errorArmed = true;
    expect(f.takeError(), ElmErrorKind.canError);
    expect(f.takeError(), isNull);
    cfg
      ..errorTrigger = ErrorTrigger.always
      ..errorArmed = true;
    expect(f.takeError(), ElmErrorKind.canError);
    expect(f.takeError(), ElmErrorKind.canError);
  });

  test('extraDelay', () {
    final cfg = FaultConfig()..delayMs = 350;
    expect(FaultInjector(cfg).extraDelay, const Duration(milliseconds: 350));
  });
}
```

`test/ecu/ecu_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/iso_tp.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/ecu/ecu.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/uds_services.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

class _Bench {
  _Bench() {
    for (final p in [engine, tcm]) {
      bus.attach(Ecu(profile: p, bus: bus, obd: obd, uds: UdsServices(), faults: faults));
    }
    bus.listen((e) {
      if (!identical(e.sender, tester)) got.add(e.frame);
    });
  }
  final bus = VirtualCanBus();
  final v = VehicleState.defaults();
  late final obd = ObdServices(v);
  final cfg = FaultConfig();
  late final faults = FaultInjector(cfg);
  final engine = EcuProfile.engine();
  final tcm = EcuProfile.transmission();
  final tester = Object();
  final got = <CanFrame>[];

  void send(int id, List<int> payload, {bool ext = false}) =>
      bus.transmit(CanFrame(id, segment(payload).single, extended: ext), sender: tester);
}

List<int> _pad(List<int> d) => [...d, ...List.filled(8 - d.length, 0)];

void main() {
  test('全 ECU 宛て 010C にエンジンが 8ms 後に応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7DF, [0x01, 0x0C]);
      async.elapse(const Duration(milliseconds: 7));
      expect(b.got, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got, [CanFrame(0x7E8, _pad([0x04, 0x41, 0x0C, 0x0C, 0x80]))]);
    });
  });

  test('トランスミッションを有効にすると 15ms 後に 7E9 も応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.tcm.enabled = true;
      b.send(0x7DF, [0x01, 0x00]);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got.map((f) => f.id), [0x7E8, 0x7E9]);
      expect(b.got[1].data, _pad([0x06, 0x41, 0x00, 0x80, 0x00, 0x00, 0x01]));
    });
  });

  test('物理アドレス 7E0 にはエンジンだけ、7E1 は無効なので無応答', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x01, 0x0D]);
      b.send(0x7E1, [0x01, 0x00]);
      async.elapse(const Duration(milliseconds: 50));
      expect(b.got.map((f) => f.id), [0x7E8]);
    });
  });

  test('29bit の全 ECU 宛て・物理アドレス', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x18DB33F1, [0x01, 0x0C], ext: true);
      b.send(0x18DA10F1, [0x01, 0x0D], ext: true);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got.map((f) => f.id), [0x18DAF110, 0x18DAF110]);
      expect(b.got.every((f) => f.extended), isTrue);
    });
  });

  test('複数フレームは FC を受けてから CF を 1ms 間隔で送る', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 8));
      expect(b.got.single.data.sublist(0, 2), [0x10, 0x14]);
      async.elapse(const Duration(milliseconds: 100));
      expect(b.got.length, 1); // FC を送るまで待つ
      b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got.length, 2);
      async.elapse(const Duration(milliseconds: 1));
      expect(b.got.map((f) => f.data[0]), [0x10, 0x21, 0x22]);
    });
  });

  test('FC のブロックサイズ 1 なら 1 フレームごとに FC を待つ', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 8));
      b.bus.transmit(CanFrame(0x7E0, flowControl(blockSize: 1)), sender: b.tester);
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 2);
      b.bus.transmit(CanFrame(0x7E0, flowControl(blockSize: 1)), sender: b.tester);
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 3);
    });
  });

  test('FC が 1000ms 来なければ送信を諦める', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7E0, [0x09, 0x02]);
      async.elapse(const Duration(milliseconds: 1100));
      b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
      async.elapse(const Duration(milliseconds: 10));
      expect(b.got.length, 1);
    });
  });

  group('障害', () {
    test('ECU 無応答', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.silentEcus.add('engine');
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.got, isEmpty);
      });
    });
    test('遅延は基本遅延に加算', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.delayMs = 100;
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 107));
        expect(b.got, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(b.got.length, 1);
      });
    });
    test('応答保留: 物理アドレスには 7F SID 78 → 1000ms 後に本応答', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.responsePending = true;
        b.send(0x7E0, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 8));
        expect(b.got.single.data, _pad([0x03, 0x7F, 0x01, 0x78]));
        async.elapse(const Duration(milliseconds: 1000));
        expect(b.got[1].data, _pad([0x04, 0x41, 0x0C, 0x0C, 0x80]));
      });
    });
    test('応答保留は全 ECU 宛てには効かない', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.responsePending = true;
        b.send(0x7DF, [0x01, 0x0C]);
        async.elapse(const Duration(milliseconds: 8));
        expect(b.got.single.data[1], 0x41);
      });
    });
    test('途中欠落: FF のみで CF は送らない', () {
      fakeAsync((async) {
        final b = _Bench()..cfg.truncateMultiFrame = true;
        b.send(0x7E0, [0x09, 0x02]);
        async.elapse(const Duration(milliseconds: 8));
        b.bus.transmit(CanFrame(0x7E0, flowControl()), sender: b.tester);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.got.length, 1);
      });
    });
  });

  test('Mode 22 は物理アドレスで応答し、全 ECU 宛てには黙る', () {
    fakeAsync((async) {
      final b = _Bench();
      b.send(0x7DF, [0x22, 0xF1, 0x87]);
      async.elapse(const Duration(milliseconds: 20));
      expect(b.got, isEmpty);
      b.send(0x7E0, [0x22, 0xF1, 0x87]);
      async.elapse(const Duration(milliseconds: 8));
      expect(b.got.single.data.sublist(0, 2), [0x10, 0x0D]);
    });
  });

  test('RTR と SF 以外は無視', () {
    fakeAsync((async) {
      final b = _Bench();
      b.bus.transmit(CanFrame(0x7DF, [], rtr: true), sender: b.tester);
      b.bus.transmit(CanFrame(0x7DF, [0x21, 1, 2]), sender: b.tester);
      async.elapse(const Duration(milliseconds: 50));
      expect(b.got, isEmpty);
    });
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/ecu/uds_services_test.dart test/can/fault_injector_test.dart test/ecu/ecu_test.dart`
Expected: FAIL（各ファイルがない）

- [ ] **Step 3: 実装する**

`lib/ecu/uds_services.dart`:

```dart
import 'ecu_profile.dart';

/// OBD 以外のサービス。Mode 22（ReadDataByIdentifier）と否定応答のみ。
class UdsServices {
  List<int>? handle(List<int> request, EcuProfile ecu, {required bool functional}) {
    if (request.isEmpty) return null;
    final sid = request[0];
    if (functional) return null;
    if (sid == 0x22) {
      if (request.length != 3) return [0x7F, 0x22, 0x13];
      final did = (request[1] << 8) | request[2];
      final value = ecu.dids[did];
      if (value == null) return [0x7F, 0x22, 0x31];
      return [0x62, request[1], request[2], ...value.bytes];
    }
    return [0x7F, sid, 0x11];
  }
}
```

`lib/can/fault_injector.dart`:

```dart
import 'dart:math';

import '../ecu/ecu_profile.dart';

/// ELM327 がエラーとして出す文言（データシート p.78–80）。
enum ElmErrorKind {
  canError('CAN ERROR'),
  busError('BUS ERROR'),
  busBusy('BUS BUSY'),
  bufferFull('BUFFER FULL'),
  dataError('DATA ERROR'),
  dataErrorMark('<DATA ERROR'),
  rxErrorMark('<RX ERROR'),
  fbError('FB ERROR'),
  err94('ERR94'),
  lvReset('LV RESET'),
  actAlert('ACT ALERT');

  const ElmErrorKind(this.text);
  final String text;

  /// 最後のデータ行の横に付ける種類。
  bool get isMark => this == dataErrorMark || this == rxErrorMark;

  /// 実機と同じく AT 設定を初期値に戻す種類。
  bool get resetsState => this == err94 || this == lvReset;
}

enum ErrorTrigger { once, always }

/// UI や CLI から変更する障害の設定。
class FaultConfig {
  bool ignitionOff = false;
  final Set<String> silentEcus = {};
  int delayMs = 0;
  int dropPercent = 0;
  bool responsePending = false;
  bool truncateMultiFrame = false;
  ElmErrorKind? error;
  ErrorTrigger errorTrigger = ErrorTrigger.once;
  bool errorArmed = false;
}

/// 障害の判定。ECU と ELM セッションが参照する。
class FaultInjector {
  FaultInjector(this.config, {Random? random}) : _random = random ?? Random();

  final FaultConfig config;
  final Random _random;

  bool isSilent(EcuProfile ecu) =>
      config.ignitionOff || config.silentEcus.contains(ecu.name);

  Duration get extraDelay => Duration(milliseconds: config.delayMs);

  /// この要求の応答をすべて捨てるか。
  bool rollDrop() =>
      config.dropPercent > 0 && _random.nextInt(100) < config.dropPercent;

  /// 発火しているエラーを取り出す。once なら取り出した時点で解除する。
  ElmErrorKind? takeError() {
    final kind = config.error;
    if (kind == null || !config.errorArmed) return null;
    if (config.errorTrigger == ErrorTrigger.once) config.errorArmed = false;
    return kind;
  }
}
```

`lib/ecu/ecu.dart`:

```dart
import 'dart:async';

import '../can/can_frame.dart';
import '../can/fault_injector.dart';
import '../can/iso_tp.dart';
import '../can/virtual_can_bus.dart';
import 'ecu_profile.dart';
import 'obd_services.dart';
import 'uds_services.dart';

enum _Addressing { functional, physical }

/// バス上の ECU。要求フレームを受け、遅延ののち ISO-TP で応答する。
class Ecu implements BusNode {
  Ecu({
    required this.profile,
    required this.bus,
    required this.obd,
    required this.uds,
    required this.faults,
  });

  final EcuProfile profile;
  final VirtualCanBus bus;
  final ObdServices obd;
  final UdsServices uds;
  final FaultInjector faults;

  static const flowControlTimeout = Duration(milliseconds: 1000);
  static const pendingDelay = Duration(milliseconds: 1000);

  final List<Timer> _timers = [];
  List<List<int>> _remaining = [];
  int _txId = 0;
  bool _txExtended = false;
  int _blockLeft = 0;
  Duration _gap = const Duration(milliseconds: 1);
  Timer? _fcTimeout;

  @override
  void onFrame(CanFrame frame) {
    if (!profile.enabled || faults.isSilent(profile) || frame.rtr) return;
    final addressing = _addressing(frame);
    if (addressing == null) return;
    final type = frameType(frame.data);
    if (type == FrameType.flowControl) {
      if (addressing == _Addressing.physical) _onFlowControl(frame.data);
      return;
    }
    if (type != FrameType.single) return;
    final n = frame.data[0] & 0x0F;
    final request = frame.data.sublist(1, 1 + n);
    final functional = addressing == _Addressing.functional;
    final response = request[0] <= 0x0A
        ? obd.handle(request, profile)
        : uds.handle(request, profile, functional: functional);
    if (response == null) return;
    final responseId = frame.extended
        ? profile.responseId29For(frame.id & 0xFF)
        : profile.responseId11;
    final delay = profile.baseLatency + faults.extraDelay;
    if (faults.config.responsePending && !functional) {
      _schedule(delay, () => _send(responseId, frame.extended, [0x7F, request[0], 0x78]));
      _schedule(delay + pendingDelay, () => _send(responseId, frame.extended, response));
    } else {
      _schedule(delay, () => _send(responseId, frame.extended, response));
    }
  }

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _fcTimeout?.cancel();
    bus.detach(this);
  }

  _Addressing? _addressing(CanFrame f) {
    if (!f.extended) {
      if (f.id == functionalId11) return _Addressing.functional;
      if (f.id == profile.requestId11) return _Addressing.physical;
      return null;
    }
    final middle = f.id & 0x00FFFF00;
    if (middle == 0x00DB3300) return _Addressing.functional;
    if (middle == (0x00DA0000 | (profile.address29 << 8))) return _Addressing.physical;
    return null;
  }

  void _schedule(Duration delay, void Function() fn) {
    late final Timer t;
    t = Timer(delay, () {
      _timers.remove(t);
      fn();
    });
    _timers.add(t);
  }

  void _send(int id, bool extended, List<int> payload) {
    if (!profile.enabled || faults.isSilent(profile)) return;
    final frames = segment(payload);
    // FF を送る前に残りを登録する（FC は FF の配信中に同期で返ってくる）。
    if (frames.length > 1 && !faults.config.truncateMultiFrame) {
      _remaining = frames.sublist(1);
      _txId = id;
      _txExtended = extended;
      _armFlowControlTimeout();
    }
    bus.transmit(CanFrame(id, frames.first, extended: extended), sender: this);
  }

  void _armFlowControlTimeout() {
    _fcTimeout?.cancel();
    _fcTimeout = Timer(flowControlTimeout, () => _remaining = []);
  }

  void _onFlowControl(List<int> data) {
    if (_remaining.isEmpty) return;
    final status = data[0] & 0x0F;
    if (status == 1) {
      _armFlowControlTimeout(); // Wait
      return;
    }
    _fcTimeout?.cancel();
    if (status != 0) {
      _remaining = []; // Overflow など
      return;
    }
    final blockSize = data.length > 1 ? data[1] : 0;
    final stMin = data.length > 2 ? data[2] : 0;
    _gap = Duration(milliseconds: stMin >= 1 && stMin <= 0x7F ? stMin : 1);
    _blockLeft = blockSize;
    _sendNextConsecutive();
  }

  void _sendNextConsecutive() {
    _schedule(_gap, () {
      if (_remaining.isEmpty) return;
      bus.transmit(CanFrame(_txId, _remaining.removeAt(0), extended: _txExtended), sender: this);
      if (_remaining.isEmpty) return;
      if (_blockLeft > 0) {
        _blockLeft--;
        if (_blockLeft == 0) {
          _armFlowControlTimeout();
          return;
        }
      }
      _sendNextConsecutive();
    });
  }
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/ecu/uds_services_test.dart test/can/fault_injector_test.dart test/ecu/ecu_test.dart`
Expected: PASS（全件）

- [ ] **Step 5: コミット**

```bash
git add lib/ecu/uds_services.dart lib/can/fault_injector.dart lib/ecu/ecu.dart test/ecu/uds_services_test.dart test/can/fault_injector_test.dart test/ecu/ecu_test.dart
git commit -m "feat: バス上のECU（遅延・ISO-TP送信・FC）、Mode 22、障害設定

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: ElmState（作り直し）と LineAssembler（空行を通す）

**Files:**
- Modify: `lib/elm327/elm_state.dart`（全置き換え）
- Modify: `lib/elm327/line_assembler.dart`（全置き換え）
- Modify: `test/line_assembler_test.dart` → `test/elm327/line_assembler_test.dart` に移して書き換え
- Modify: `lib/elm327/at_command_handler.dart`, `lib/elm327/obd_command_handler.dart`, `test/at_command_handler_test.dart`, `test/obd_command_handler_test.dart`（新しい ElmState で旧コードが動くよう最小限だけ直す。Task 13 で削除する）
- Test: `test/elm327/elm_state_test.dart`

**Interfaces:**
- Consumes: `CanFrame`（Task 1）
- Produces:
  - `enum AdaptiveTiming { off, auto1, auto2 }`
  - `const Map<int, String> protocolNames`（1〜C）
  - `class ElmState`:
    - 表示: `echo, linefeed, spaces, headers, dlc, caf, responses, allowLong, variableDlc, autoFlowControl`（bool）
    - プロトコル: `int protocol`, `bool autoSearch`, `int? established`, `int storedProtocol`, `bool storedAuto`, `void setProtocol(int p, {required bool auto, required bool save})`, `int get activeProtocol`, `bool get is29bit`, `static bool isCanProtocol(int p)`, `String describeProtocol()`, `String describeProtocolNumber()`
    - アドレス: `int? header`, `int priority29`, `int testerAddress`, `int? receiveAddress, craId, filterId, maskId, extendedAddress`, `int get txId`, `bool acceptsResponse(CanFrame f)`, `bool acceptsMonitor(CanFrame f, {int? receiver, int? transmitter})`
    - タイミング: `int timeoutHex`, `AdaptiveTiming timing`, `Duration get timeout`
    - 保存のみ: `flowMode`, `flowHeader`, `flowData`, `deviceId`, `storedByte`, `ppValues`, `ppEnabled`, `memory`, `activityTimeout`, `voltageOffset`
    - 実行時: `lastCommand`, `lastFrame`, `lastActivity`, `txErrors`, `rxErrors`
    - `void defaults()`（AT D）、`void reset()`（AT Z / WS）
  - `class LineAssembler { List<String> addBytes(List<int> bytes); }` — CR で 1 行（空行は `''`）。LF・NUL・その他 0x20 未満は捨てる。スペースは残す（エコー用）。

- [ ] **Step 1: 失敗するテストを書く**

`test/elm327/elm_state_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/elm327/elm_state.dart';

void main() {
  late ElmState s;
  setUp(() => s = ElmState());

  test('初期値', () {
    expect(s.echo, isTrue);
    expect(s.linefeed, isFalse);
    expect(s.spaces, isTrue);
    expect(s.headers, isFalse);
    expect(s.caf, isTrue);
    expect(s.protocol, 0);
    expect(s.autoSearch, isTrue);
    expect(s.timeout, const Duration(milliseconds: 200));
    expect(s.timing, AdaptiveTiming.auto1);
    expect(s.txId, 0x7DF);
  });

  group('プロトコル', () {
    test('未確定の自動は AUTO / A0、確定後は AUTO, 名前 / A6', () {
      expect(s.describeProtocol(), 'AUTO');
      expect(s.describeProtocolNumber(), 'A0');
      expect(s.activeProtocol, 6);
      s.established = 6;
      expect(s.describeProtocol(), 'AUTO, ISO 15765-4 (CAN 11/500)');
      expect(s.describeProtocolNumber(), 'A6');
    });
    test('固定の 7 は 29bit、名前だけ', () {
      s.setProtocol(7, auto: false, save: true);
      expect(s.is29bit, isTrue);
      expect(s.describeProtocol(), 'ISO 15765-4 (CAN 29/500)');
      expect(s.describeProtocolNumber(), '7');
    });
    test('自動で CAN 以外から始めても送信は 6（11bit）', () {
      s.setProtocol(3, auto: true, save: false);
      expect(s.activeProtocol, 6);
      expect(s.describeProtocol(), 'AUTO, ISO 9141-2');
    });
    test('固定の CAN 以外は activeProtocol もそのまま', () {
      s.setProtocol(3, auto: false, save: false);
      expect(s.activeProtocol, 3);
      expect(ElmState.isCanProtocol(s.activeProtocol), isFalse);
    });
    test('プロトコルを変えると確定は解除', () {
      s.established = 6;
      s.setProtocol(8, auto: false, save: false);
      expect(s.established, isNull);
    });
    test('保存したプロトコルは reset / defaults の後も残る（p.13, p.24）', () {
      s.setProtocol(7, auto: false, save: true);
      s.reset();
      expect(s.protocol, 7);
      expect(s.autoSearch, isFalse);
      s.setProtocol(8, auto: false, save: false); // TP 相当
      s.defaults();
      expect(s.protocol, 7);
    });
  });

  group('送信 ID', () {
    test('29bit の既定は 18DB33F1', () {
      s.setProtocol(7, auto: false, save: false);
      expect(s.txId, 0x18DB33F1);
    });
    test('SH 7E0 は 11bit ID', () {
      s.header = 0x7E0;
      expect(s.txId, 0x7E0);
    });
    test('SH DA10F1 と CP で 29bit ID', () {
      s.setProtocol(7, auto: false, save: false);
      s.header = 0xDA10F1;
      expect(s.txId, 0x18DA10F1);
      s.priority29 = 0x1B;
      expect(s.txId, 0x1BDA10F1);
    });
    test('TA で既定の 29bit 送信元が変わる', () {
      s.setProtocol(7, auto: false, save: false);
      s.testerAddress = 0xF2;
      expect(s.txId, 0x18DB33F2);
    });
  });

  group('受信フィルタ', () {
    CanFrame f(int id, {bool ext = false}) => CanFrame(id, [0], extended: ext);
    test('既定: 11bit は 7E8〜7EF のみ', () {
      expect(s.acceptsResponse(f(0x7E8)), isTrue);
      expect(s.acceptsResponse(f(0x7EF)), isTrue);
      expect(s.acceptsResponse(f(0x7E0)), isFalse);
      expect(s.acceptsResponse(f(0x0C9)), isFalse);
      expect(s.acceptsResponse(f(0x18DAF110, ext: true)), isFalse);
    });
    test('既定: 29bit は 18DAF1xx', () {
      s.setProtocol(7, auto: false, save: false);
      expect(s.acceptsResponse(f(0x18DAF110, ext: true)), isTrue);
      expect(s.acceptsResponse(f(0x18DAF210, ext: true)), isFalse);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('CRA は ID 完全一致', () {
      s.craId = 0x7E9;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('CF / CM', () {
      s
        ..filterId = 0x7E8
        ..maskId = 0x7FE;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7EA)), isFalse);
    });
    test('RA: 11bit は下位 8bit', () {
      s.receiveAddress = 0xE9;
      expect(s.acceptsResponse(f(0x7E9)), isTrue);
      expect(s.acceptsResponse(f(0x7E8)), isFalse);
    });
    test('監視: 既定のフィルタは使わず全部通す。MR / MT で絞る', () {
      expect(s.acceptsMonitor(f(0x0C9)), isTrue);
      expect(s.acceptsMonitor(f(0x0C9), transmitter: 0xC9), isTrue);
      expect(s.acceptsMonitor(f(0x3E9), transmitter: 0xC9), isFalse);
      expect(s.acceptsMonitor(f(0x7E8), receiver: 0x07), isTrue);
      expect(s.acceptsMonitor(f(0x18DAF110, ext: true)), isFalse); // 11bit 中
    });
  });

  test('reset は表示設定と実行時状態を戻し、保存値（@3・SD・PP・CV）は残す', () {
    s
      ..echo = false
      ..headers = true
      ..header = 0x7E0
      ..timeoutHex = 0x10
      ..lastCommand = '010C'
      ..txErrors = 3
      ..deviceId = 'ABCDEFGHIJKL'
      ..storedByte = 0x5A
      ..voltageOffset = 0.3;
    s.ppValues[0x0C] = 0x68;
    s.reset();
    expect(s.echo, isTrue);
    expect(s.headers, isFalse);
    expect(s.header, isNull);
    expect(s.timeoutHex, 0x32);
    expect(s.lastCommand, isNull);
    expect(s.txErrors, 0);
    expect(s.deviceId, 'ABCDEFGHIJKL');
    expect(s.storedByte, 0x5A);
    expect(s.voltageOffset, 0.3);
    expect(s.ppValues[0x0C], 0x68);
  });

  test('defaults は lastCommand を残す', () {
    s.lastCommand = '010C';
    s.defaults();
    expect(s.lastCommand, '010C');
  });
}
```

`test/elm327/line_assembler_test.dart`（`test/line_assembler_test.dart` を削除してこちらに置く）:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/elm327/line_assembler.dart';

List<int> b(String s) => s.codeUnits;

void main() {
  test('1 行を 1 コマンドとして返す', () {
    expect(LineAssembler().addBytes(b('010C\r')), ['010C']);
  });

  test('CR が来るまでは何も返さない', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010')), isEmpty);
    expect(a.addBytes(b('C\r')), ['010C']);
  });

  test('複数行を一度に分割する', () {
    expect(LineAssembler().addBytes(b('ATZ\r010C\r')), ['ATZ', '010C']);
  });

  test('LF・NUL・制御文字は捨て、空行は空文字として返す（旧: 捨てる）', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r\n')), ['ATZ']);
    expect(a.addBytes(b('\r')), ['']);
    expect(a.addBytes([0x00, 0x01, 0x41, 0x54, 0x49, 0x0D]), ['ATI']);
  });

  test('スペースと DEL は残す（エコーと ? 判定のため）', () {
    expect(LineAssembler().addBytes(b('AT RV\r')), ['AT RV']);
    expect(LineAssembler().addBytes([0x7F, 0x7F, 0x0D]), ['\x7F\x7F']);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/elm327/elm_state_test.dart test/elm327/line_assembler_test.dart`
Expected: FAIL（`describeProtocol` 未定義、空行が返らない など）

- [ ] **Step 3: 実装する**

`lib/elm327/elm_state.dart`（全置き換え）:

```dart
import '../can/can_frame.dart';

enum AdaptiveTiming { off, auto1, auto2 }

/// プロトコル番号 → 名前（ATDP の表示。データシート p.24）。
const Map<int, String> protocolNames = {
  0x1: 'SAE J1850 PWM',
  0x2: 'SAE J1850 VPW',
  0x3: 'ISO 9141-2',
  0x4: 'ISO 14230-4 (KWP 5BAUD)',
  0x5: 'ISO 14230-4 (KWP FAST)',
  0x6: 'ISO 15765-4 (CAN 11/500)',
  0x7: 'ISO 15765-4 (CAN 29/500)',
  0x8: 'ISO 15765-4 (CAN 11/250)',
  0x9: 'ISO 15765-4 (CAN 29/250)',
  0xA: 'SAE J1939 (CAN 29/250)',
  0xB: 'USER1 CAN (11* /125)',
  0xC: 'USER2 CAN (11* /50)',
};

/// ELM327 の設定と実行時の状態（1 接続ぶん）。
class ElmState {
  ElmState() {
    defaults();
  }

  // ---- AT D / AT Z で初期値に戻るもの ----
  late bool echo, linefeed, spaces, headers, dlc, caf, responses;
  late bool allowLong, variableDlc, autoFlowControl;
  late int protocol;
  late bool autoSearch;
  int? established;
  int? header; // SH で設定した値（11bit はその下位 11bit、29bit は下位 3 バイト）
  late int priority29, testerAddress;
  int? receiveAddress, craId, filterId, maskId, extendedAddress;
  late int timeoutHex;
  late AdaptiveTiming timing;
  late int flowMode;
  int? flowHeader;
  List<int>? flowData;

  // ---- 電源を切っても残るもの（EEPROM 相当） ----
  int storedProtocol = 0;
  bool storedAuto = true;
  String? deviceId;
  int storedByte = 0;
  final Map<int, int> ppValues = {};
  final Set<int> ppEnabled = {};
  bool memory = true;
  int activityTimeout = 0;
  double? voltageOffset;

  // ---- 実行時 ----
  String? lastCommand;
  CanFrame? lastFrame;
  DateTime? lastActivity;
  int txErrors = 0;
  int rxErrors = 0;

  /// AT D。保存したプロトコルを読み戻し、ヘッダ・フィルタ・タイマーを初期値にする（p.13）。
  void defaults() {
    echo = true;
    linefeed = false;
    spaces = true;
    headers = false;
    dlc = false;
    caf = true;
    responses = true;
    allowLong = false;
    variableDlc = false;
    autoFlowControl = true;
    protocol = storedProtocol;
    autoSearch = storedAuto;
    established = null;
    header = null;
    priority29 = 0x18;
    testerAddress = 0xF1;
    receiveAddress = null;
    craId = null;
    filterId = null;
    maskId = null;
    extendedAddress = null;
    timeoutHex = 0x32;
    timing = AdaptiveTiming.auto1;
    flowMode = 0;
    flowHeader = null;
    flowData = null;
  }

  /// AT Z / AT WS。電源を入れ直したのと同じ。
  void reset() {
    defaults();
    lastCommand = null;
    lastFrame = null;
    txErrors = 0;
    rxErrors = 0;
  }

  /// SP / TP。[save] は SP h・SP Ah・SP 00 のとき true（SP 0 と TP は保存しない）。
  void setProtocol(int p, {required bool auto, required bool save}) {
    protocol = p;
    autoSearch = auto || p == 0;
    established = null;
    if (save) {
      storedProtocol = p;
      storedAuto = autoSearch;
    }
  }

  static bool isCanProtocol(int p) => p >= 6 && p <= 9;

  /// 送信に使うプロトコル。自動で CAN 以外から始めた場合も CAN 6 で探す。
  int get activeProtocol {
    final e = established;
    if (e != null) return e;
    if (isCanProtocol(protocol)) return protocol;
    return autoSearch ? 6 : protocol;
  }

  bool get is29bit => activeProtocol == 7 || activeProtocol == 9;

  String describeProtocol() {
    final n = established ?? protocol;
    if (autoSearch) return n == 0 ? 'AUTO' : 'AUTO, ${protocolNames[n]}';
    return protocolNames[n] ?? 'AUTO';
  }

  String describeProtocolNumber() {
    final n = (established ?? protocol).toRadixString(16).toUpperCase();
    return autoSearch ? 'A$n' : n;
  }

  Duration get timeout =>
      Duration(milliseconds: (timeoutHex == 0 ? 0x32 : timeoutHex) * 4);

  int get txId {
    final h = header;
    if (is29bit) {
      final low = h ?? (0xDB3300 | testerAddress);
      return ((priority29 & 0x1F) << 24) | (low & 0xFFFFFF);
    }
    return h == null ? 0x7DF : h & 0x7FF;
  }

  /// 要求への応答として受け取るフレームか。
  bool acceptsResponse(CanFrame f) {
    if (f.extended != is29bit) return false;
    final user = _userFilter(f);
    if (user != null) return user;
    if (is29bit) return (f.id & 0x00FFFF00) == (0x00DA0000 | (testerAddress << 8));
    return f.id >= 0x7E8 && f.id <= 0x7EF;
  }

  /// 監視（ATMA / MR / MT）で表示するフレームか。既定の 7E8〜7EF フィルタは使わない。
  bool acceptsMonitor(CanFrame f, {int? receiver, int? transmitter}) {
    if (f.extended != is29bit) return false;
    if (_userFilter(f) == false) return false;
    if (receiver != null) {
      final r = f.extended ? (f.id >> 8) & 0xFF : (f.id >> 8) & 0x07;
      if (r != receiver) return false;
    }
    if (transmitter != null && (f.id & 0xFF) != transmitter) return false;
    return true;
  }

  bool? _userFilter(CanFrame f) {
    final cra = craId;
    if (cra != null) return f.id == cra;
    final mask = maskId;
    if (mask != null) return (f.id & mask) == ((filterId ?? 0) & mask);
    final ra = receiveAddress;
    if (ra != null) {
      return f.extended ? ((f.id >> 8) & 0xFF) == ra : (f.id & 0xFF) == ra;
    }
    return null;
  }
}
```

`lib/elm327/line_assembler.dart`（全置き換え）:

```dart
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
```

旧コードの最小修正（Task 13 で削除するまで動かすため）:

`lib/elm327/at_command_handler.dart` の `DPN` の行と `SP` の分岐を次に置き換える:

```dart
    if (body == 'DPN') return state.describeProtocolNumber();
```

```dart
    if (body.startsWith('SP')) {
      final p = body.substring(2).replaceFirst('A', '');
      final n = int.tryParse(p, radix: 16);
      if (n != null) state.setProtocol(n, auto: n == 0, save: true);
      return 'OK';
    }
```

`lib/elm327/obd_command_handler.dart` の `if (!state.initialized) { state.initialized = true; … }` を次に置き換える:

```dart
    if (state.established == null) {
      state.established = state.activeProtocol;
      searching.add('SEARCHING...');
    }
```

旧テストの `initialized` を使う箇所を置き換える（期待値は変えない）:
- `test/obd_command_handler_test.dart` の `state = ElmState()..initialized = true;` → `state = ElmState()..established = 6;`、`state.initialized = false;` → `state.established = null;`、`expect(state.initialized, isTrue);` → `expect(state.established, isNotNull);`
- `test/elm327_engine_test.dart` の `e.state.initialized = true;` → `e.state.established = 6;`
- `test/at_command_handler_test.dart` の `ATDPN はプロトコル番号` の期待値 `'6'` → `'A0'`、`ATSP6 でプロトコル設定` / `ATSP0 …` / `ATSPA6 …` の `expect(state.protocol, 6);` はそのまま（ATSP0 のテストだけ `expect(state.protocol, 0);` に変える。旧テストは Task 13 で消えるため、ここでの変更は一時的なもの）

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test`
Expected: 全件 PASS（新規の ElmState・LineAssembler のテストと、最小修正した旧テスト）

- [ ] **Step 5: コミット**

```bash
git rm test/line_assembler_test.dart
git add lib/elm327/elm_state.dart lib/elm327/line_assembler.dart lib/elm327/at_command_handler.dart lib/elm327/obd_command_handler.dart test/elm327/ test/at_command_handler_test.dart test/obd_command_handler_test.dart test/elm327_engine_test.dart
git commit -m "feat: ElmState を作り直し（プロトコル保存・送信ID・受信フィルタ）、空行を通す

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: ResponseFormatter（受信フレーム → 表示行）

**Files:**
- Create: `lib/elm327/response_formatter.dart`
- Test: `test/elm327/response_formatter_test.dart`

**Interfaces:**
- Consumes: `CanFrame`（Task 1）、`frameType`, `FrameType`（Task 2）、`ElmState`（Task 7）、`hex2`, `hexN`（Task 1）
- Produces:
  - `class ResponseFormatter { ResponseFormatter(ElmState state); List<String> frameLines(CanFrame f, {bool monitor = false}); String bytes(List<int> data); String idText(CanFrame f); void reset(); }`
  - 規則（設計 §7.1）:
    - H1 / CAF0 / 監視中: 1 フレーム 1 行。`[ID][DLC][FC:]データ 8 バイト全部`。ID は H1 のときだけ、DLC は H1 かつ D1 のときだけ（p.13）。`FC: ` は監視中の FC フレームのみ。RTR は CAF0 または H1 で `RTR`、CAF1 かつ H0 では出さない
    - H0 かつ CAF1: SF → PCI とパディングを除いたデータ。FF → 総バイト数 3 桁の行と `0: ` + 6 バイト。CF → `連番: ` + 残りバイト（最終フレームのパディングは除く）。FC・不正 PCI は出さない
    - S1 はバイトの間と行末にスペース、S0 は区切りなし

- [ ] **Step 1: 失敗するテストを書く**

`test/elm327/response_formatter_test.dart`:

```dart
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
    expect(fmt.frameLines(sf([0x41, 0x05, 0x46])), ['7E8 03 41 05 46 00 00 00 00 ']);
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
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98], id: 0x18DAF110, ext: true)),
        ['18 DA F1 10 04 41 0C 21 98 00 00 00 ']);
  });

  test('H0 CAF0: PCI とパディングも表示', () {
    s.caf = false;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['04 41 0C 21 98 00 00 00 ']);
  });

  test('D1 は H1 のときだけ DLC を表示（p.13）', () {
    s.dlc = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['41 0C 21 98 ']);
    s.headers = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])),
        ['7E8 8 04 41 0C 21 98 00 00 00 ']);
  });

  test('S0 は区切りなし', () {
    s.spaces = false;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['410C2198']);
    expect(vinLines()[1], '0:490201574155');
    s.headers = true;
    expect(fmt.frameLines(sf([0x41, 0x0C, 0x21, 0x98])), ['7E804410C2198000000']);
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
    expect(fmt.frameLines(CanFrame(0x7E8, [0x21, 1, 2, 3, 4, 5, 6, 7])), isEmpty);
    expect(fmt.frameLines(CanFrame(0x7E8, flowControl())), isEmpty);
    expect(fmt.frameLines(CanFrame(0x7E8, [0x00, 0, 0, 0, 0, 0, 0, 0])), isEmpty);
  });

  test('監視中: 生の 8 バイト、FC は "FC: " 付き（p.45）', () {
    expect(fmt.frameLines(CanFrame(0x0C9, [0x0C, 0x80, 0x1E, 0, 0, 0, 0, 0]), monitor: true),
        ['0C 80 1E 00 00 00 00 00 ']);
    s.headers = true;
    expect(fmt.frameLines(CanFrame(0x7E0, flowControl()), monitor: true),
        ['7E0 FC: 30 00 00 00 00 00 00 00 ']);
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
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/elm327/response_formatter_test.dart`
Expected: FAIL（`response_formatter.dart` がない）

- [ ] **Step 3: 実装する**

`lib/elm327/response_formatter.dart`:

```dart
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
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/elm327/response_formatter_test.dart`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/elm327/response_formatter.dart test/elm327/response_formatter_test.dart
git commit -m "feat: ResponseFormatter（H/S/D/CAF・複数フレーム・監視表示）

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: AtCommands（データシートの全 AT コマンド）

**Files:**
- Create: `lib/elm327/at_commands.dart`
- Test: `test/elm327/at_commands_test.dart`

**Interfaces:**
- Consumes: `ElmState`, `AdaptiveTiming`（Task 7）、`CanFrame`（Task 1）、`hex2`（Task 1）、`package:clock`
- Produces:
  - `const elmId = 'ELM327 v1.5'; const elmDescription = 'OBDII to RS232 Interpreter';`
  - `sealed class AtOutcome`、`AtReply(List<String> lines)`、`AtReset()`、`AtLowPower()`、`AtMonitor({int? receiver, int? transmitter})`、`AtRtr()`
  - `class AtCommands { AtCommands(ElmState state, {required double Function() voltage, required bool Function() ignitionOn}); AtOutcome handle(String body, {String raw = ''}); }`
  - `body` は行から先頭の `AT` を除き、スペースを抜いて大文字にしたもの。`raw` は元の行（`@3` の文字列を大文字・スペースそのままで取るため）。

- [ ] **Step 1: 失敗するテストを書く**

`test/elm327/at_commands_test.dart`:

```dart
import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/elm327/at_commands.dart';
import 'package:elm327emu/elm327/elm_state.dart';

void main() {
  late ElmState s;
  late AtCommands at;
  var volts = 12.4;
  var ignition = true;
  setUp(() {
    s = ElmState();
    volts = 12.4;
    ignition = true;
    at = AtCommands(s, voltage: () => volts, ignitionOn: () => ignition);
  });

  List<String> reply(String body, {String raw = ''}) {
    final o = at.handle(body, raw: raw);
    expect(o, isA<AtReply>(), reason: body);
    return (o as AtReply).lines;
  }

  void ok(String body) => expect(reply(body), ['OK'], reason: body);
  void q(String body) => expect(reply(body), ['?'], reason: body);

  group('全般', () {
    test('Z / WS は reset して AtReset', () {
      s.echo = false;
      expect(at.handle('Z'), isA<AtReset>());
      expect(s.echo, isTrue);
      s.headers = true;
      expect(at.handle('WS'), isA<AtReset>());
      expect(s.headers, isFalse);
    });
    test('D は初期値に戻して OK', () {
      s.headers = true;
      ok('D');
      expect(s.headers, isFalse);
    });
    test('I / @1', () {
      expect(reply('I'), [elmId]);
      expect(reply('@1'), [elmDescription]);
    });
    test('@2 は未保存なら ?、@3 は 12 文字ちょうどを 1 回だけ保存（p.26）', () {
      q('@2');
      expect(reply('@3SHORT', raw: 'AT@3 SHORT'), ['?']);
      expect(reply('@3ABCDEFGHIJKLM', raw: 'AT@3 ABCDEFGHIJKLM'), ['?']); // 13 文字
      // スペースと小文字はそのまま保存する（'SN-001 2026x' は 12 文字）
      expect(reply('@3SN-0012026X', raw: 'AT@3 SN-001 2026x'), ['OK']);
      expect(reply('@2'), ['SN-001 2026x']);
      expect(reply('@3OTHER0000000', raw: 'AT@3 OTHER0000000'), ['?']); // 2 回目
    });
    test('E / L / M / H / S / R / V / D0/1 / CAF / CFC', () {
      ok('E0');
      expect(s.echo, isFalse);
      ok('L1');
      expect(s.linefeed, isTrue);
      ok('M0');
      expect(s.memory, isFalse);
      ok('H1');
      expect(s.headers, isTrue);
      ok('S0');
      expect(s.spaces, isFalse);
      ok('R0');
      expect(s.responses, isFalse);
      ok('V1');
      expect(s.variableDlc, isTrue);
      ok('D1');
      expect(s.dlc, isTrue);
      ok('CAF0');
      expect(s.caf, isFalse);
      ok('CFC0');
      expect(s.autoFlowControl, isFalse);
      q('E2');
    });
    test('SD / RD', () {
      ok('SD5A');
      expect(reply('RD'), ['5A']);
    });
    test('BRD は 00 以外 OK（p.12）、BRT / FE は OK', () {
      ok('BRD23');
      q('BRD00');
      ok('BRT0F');
      ok('FE');
    });
    test('LP は AtLowPower', () {
      expect(at.handle('LP'), isA<AtLowPower>());
    });
    test('PP と PPS（番号:値 N/F、1 行 4 項目、00〜2F）', () {
      ok('PP0CSV68');
      ok('PP0CON');
      ok('PPFFOFF');
      expect(s.ppEnabled, isEmpty);
      ok('PP0CON');
      final lines = reply('PPS');
      expect(lines.length, 12);
      expect(lines.first, '00:FF F  01:FF F  02:FF F  03:FF F');
      expect(lines[3], '0C:68 N  0D:FF F  0E:FF F  0F:FF F');
      expect(lines[9].startsWith('24:FF F  25:FF F  26:00 F'), isTrue);
      ok('PPFFON');
      expect(s.ppEnabled.length, 0x30);
      ok('PP0COFF');
      expect(s.ppEnabled.contains(0x0C), isFalse);
    });
    test('RV は車両電圧、CV で補正、CV 0000 で解除', () {
      expect(reply('RV'), ['12.4V']);
      ok('CV1250');
      expect(reply('RV'), ['12.5V']);
      volts = 13.0;
      expect(reply('RV'), ['13.1V']);
      ok('CV0000');
      expect(reply('RV'), ['13.0V']);
    });
    test('IGN', () {
      expect(reply('IGN'), ['ON']);
      ignition = false;
      expect(reply('IGN'), ['OFF']);
    });
  });

  group('OBD 全般', () {
    test('AL / NL', () {
      ok('AL');
      expect(s.allowLong, isTrue);
      ok('NL');
      expect(s.allowLong, isFalse);
    });
    test('AMC は最後の通信からの経過（0.65536 秒単位、上限 FF）、AMT は保存', () {
      withClock(Clock.fixed(DateTime(2026, 1, 1, 0, 0, 10)), () {
        s.lastActivity = DateTime(2026, 1, 1, 0, 0, 0);
        expect(reply('AMC'), ['0F']); // 10 / 0.65536 = 15.2
        s.lastActivity = DateTime(2025, 1, 1);
        expect(reply('AMC'), ['FF']);
        s.lastActivity = null;
        expect(reply('AMC'), ['FF']);
      });
      ok('AMT20');
      expect(s.activityTimeout, 0x20);
    });
    test('AR は受信アドレスを解除、RA / SR は設定', () {
      ok('RAE9');
      expect(s.receiveAddress, 0xE9);
      ok('AR');
      expect(s.receiveAddress, isNull);
      ok('SRE8');
      expect(s.receiveAddress, 0xE8);
    });
    test('AT0 / AT1 / AT2', () {
      ok('AT0');
      expect(s.timing, AdaptiveTiming.off);
      ok('AT2');
      expect(s.timing, AdaptiveTiming.auto2);
      q('AT3');
    });
    test('BD は長さ + 12 バイト', () {
      expect(reply('BD'), ['00 00 00 00 00 00 00 00 00 00 00 00 00']);
      s.lastFrame = CanFrame(0x7E8, [0x04, 0x41, 0x0C, 0x21, 0x98, 0, 0, 0]);
      expect(reply('BD'), ['0A 07 E8 04 41 0C 21 98 00 00 00 00 00']);
    });
    test('BI / PC / SS は OK', () {
      ok('BI');
      ok('PC');
      ok('SS');
    });
    test('DP / DPN', () {
      expect(reply('DP'), ['AUTO']);
      expect(reply('DPN'), ['A0']);
      ok('SP6');
      expect(reply('DP'), ['ISO 15765-4 (CAN 11/500)']);
      expect(reply('DPN'), ['6']);
    });
    test('MA / MR / MT は AtMonitor', () {
      expect(at.handle('MA'), isA<AtMonitor>());
      final mr = at.handle('MR07') as AtMonitor;
      expect(mr.receiver, 0x07);
      final mt = at.handle('MTC9') as AtMonitor;
      expect(mt.transmitter, 0xC9);
    });
    test('SH は 3 / 6 / 8 桁、それ以外は ?', () {
      ok('SH7E0');
      expect(s.header, 0x7E0);
      ok('SHDA10F1');
      expect(s.header, 0xDA10F1);
      ok('SH1BDA10F1');
      expect(s.priority29, 0x1B);
      expect(s.header, 0xDA10F1);
      q('SH7E');
      q('SH');
    });
    test('SP / SPA / SP00 / TP / TPA（保存するかどうか）', () {
      ok('SP7');
      expect(s.storedProtocol, 7);
      expect(s.autoSearch, isFalse);
      ok('SP0');
      expect(s.autoSearch, isTrue);
      expect(s.storedProtocol, 7); // SP 0 は保存しない
      ok('SPA8');
      expect(s.storedProtocol, 8);
      expect(s.storedAuto, isTrue);
      ok('SP00');
      expect(s.storedProtocol, 0);
      ok('TP9');
      expect(s.protocol, 9);
      expect(s.storedProtocol, 0);
      ok('TPA6');
      expect(s.autoSearch, isTrue);
      q('SP');
      q('SPD');
    });
    test('ST は ×4ms、00 は初期値', () {
      ok('ST19');
      expect(s.timeout, const Duration(milliseconds: 100));
      ok('ST00');
      expect(s.timeoutHex, 0x32);
    });
    test('TA', () {
      ok('TAF2');
      expect(s.testerAddress, 0xF2);
    });
  });

  group('CAN', () {
    test('CEA / CEA hh', () {
      ok('CEA05');
      expect(s.extendedAddress, 0x05);
      ok('CEA');
      expect(s.extendedAddress, isNull);
    });
    test('CF / CM（3 桁・8 桁）', () {
      ok('CF7E8');
      ok('CM7FE');
      expect(s.filterId, 0x7E8);
      expect(s.maskId, 0x7FE);
      ok('CF18DAF110');
      ok('CM1FFFFFFF');
      expect(s.filterId, 0x18DAF110);
      q('CF7E');
    });
    test('CP / CRA / CS / CSM', () {
      ok('CP1B');
      expect(s.priority29, 0x1B);
      ok('CRA7E9');
      expect(s.craId, 0x7E9);
      ok('CRA18DAF110');
      expect(s.craId, 0x18DAF110);
      ok('CF7E8');
      ok('CM7FF');
      ok('CRA');
      expect(s.craId, isNull);
      expect(s.maskId, isNull);
      s.txErrors = 3;
      expect(reply('CS'), ['T:03 R:00']);
      ok('CSM0');
    });
    test('FC SM は 0〜2、1 と 2 は必要なデータがないと ?（p.15）', () {
      ok('FCSM0');
      q('FCSM1');
      q('FCSM2');
      ok('FCSD300000');
      ok('FCSM2');
      q('FCSM1');
      ok('FCSH7E0');
      ok('FCSM1');
      expect(s.flowMode, 1);
      q('FCSM3');
      q('FCSD');
      ok('FCSH18DA10F1');
    });
    test('PB は OK、RTR は AtRtr', () {
      ok('PBC001');
      expect(at.handle('RTR'), isA<AtRtr>());
    });
  });

  group('CAN 以外', () {
    test('設定系は OK', () {
      for (final c in [
        'IFR0', 'IFR1', 'IFR2', 'IFRH', 'IFRS', 'IB10', 'IB48', 'IB96', 'IIA13', //
        'KW0', 'KW1', 'SW92', 'SW00', 'WM8110F13E', 'JE', 'JS', 'JHF0', 'JHF1', 'JTM1', 'JTM5',
      ]) {
        ok(c);
      }
    });
    test('実行系は ?（p.78）', () {
      for (final c in ['FI', 'SI', 'KW', 'DM1', 'MPFECA', 'MPFECA5', 'MP00FECA', 'MP00FECA3']) {
        q(c);
      }
    });
  });

  test('未知・空は ?', () {
    q('XYZ');
    q('');
    q('E');
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/elm327/at_commands_test.dart`
Expected: FAIL（`at_commands.dart` がない）

- [ ] **Step 3: 実装する**

`lib/elm327/at_commands.dart`:

```dart
import 'dart:math' as math;

import 'package:clock/clock.dart';

import '../util/hex.dart';
import 'elm_state.dart';

const elmId = 'ELM327 v1.5';
const elmDescription = 'OBDII to RS232 Interpreter';

/// AT コマンドの結果。
sealed class AtOutcome {
  const AtOutcome();
}

class AtReply extends AtOutcome {
  const AtReply(this.lines);
  final List<String> lines;
}

/// Z / WS。セッションが空行 2 つと ID を出す。
class AtReset extends AtOutcome {
  const AtReset();
}

class AtLowPower extends AtOutcome {
  const AtLowPower();
}

class AtMonitor extends AtOutcome {
  const AtMonitor({this.receiver, this.transmitter});
  final int? receiver;
  final int? transmitter;
}

class AtRtr extends AtOutcome {
  const AtRtr();
}

class _Rule {
  _Rule(String pattern, this.run) : pattern = RegExp('^$pattern\$');
  final RegExp pattern;
  final AtOutcome Function(RegExpMatch m, String raw) run;
}

/// データシート（ELM327DSI v2.0）p.9–10 の AT コマンド一覧を 4 段階（動作・保存・OK・?）で扱う。
class AtCommands {
  AtCommands(this.state, {required this.voltage, required this.ignitionOn});

  final ElmState state;
  final double Function() voltage;
  final bool Function() ignitionOn;

  static const _ok = AtReply(['OK']);
  static const _q = AtReply(['?']);
  static const _hx = '[0-9A-F]';

  AtOutcome handle(String body, {String raw = ''}) {
    for (final rule in _rules) {
      final m = rule.pattern.firstMatch(body);
      if (m != null) return rule.run(m, raw);
    }
    return _q;
  }

  AtOutcome _set(void Function() apply) {
    apply();
    return _ok;
  }

  int _h(RegExpMatch m, [int group = 1]) => int.parse(m.group(group)!, radix: 16);
  bool _b(RegExpMatch m) => m.group(1) == '1';

  late final List<_Rule> _rules = [
    // ---- 全般 ----
    _Rule('Z', (m, r) => _reset()),
    _Rule('WS', (m, r) => _reset()),
    _Rule('D', (m, r) => _set(state.defaults)),
    _Rule('I', (m, r) => const AtReply([elmId])),
    _Rule('@1', (m, r) => const AtReply([elmDescription])),
    _Rule('@2', (m, r) => state.deviceId == null ? _q : AtReply([state.deviceId!])),
    _Rule('@3.*', (m, r) => _storeDeviceId(r)),
    _Rule('E([01])', (m, r) => _set(() => state.echo = _b(m))),
    _Rule('L([01])', (m, r) => _set(() => state.linefeed = _b(m))),
    _Rule('M([01])', (m, r) => _set(() => state.memory = _b(m))),
    _Rule('SD($_hx{2})', (m, r) => _set(() => state.storedByte = _h(m))),
    _Rule('RD', (m, r) => AtReply([hex2(state.storedByte)])),
    _Rule('BRD($_hx{2})', (m, r) => _h(m) == 0 ? _q : _ok),
    _Rule('BRT$_hx{2}', (m, r) => _ok),
    _Rule('FE', (m, r) => _ok),
    _Rule('LP', (m, r) => const AtLowPower()),
    _Rule('PP($_hx{2})ON', (m, r) => _set(() => _ppRange(_h(m)).forEach(state.ppEnabled.add))),
    _Rule('PP($_hx{2})OFF', (m, r) => _set(() => _ppRange(_h(m)).forEach(state.ppEnabled.remove))),
    _Rule('PP($_hx{2})SV($_hx{2})', (m, r) => _set(() => state.ppValues[_h(m)] = _h(m, 2))),
    _Rule('PPS', (m, r) => AtReply(_ppSummary())),
    _Rule(r'CV(\d{4})', (m, r) => _calibrate(int.parse(m.group(1)!))),
    _Rule('RV', (m, r) => AtReply(['${(voltage() + (state.voltageOffset ?? 0)).toStringAsFixed(1)}V'])),
    _Rule('IGN', (m, r) => AtReply([ignitionOn() ? 'ON' : 'OFF'])),
    // ---- OBD 全般 ----
    _Rule('AL', (m, r) => _set(() => state.allowLong = true)),
    _Rule('NL', (m, r) => _set(() => state.allowLong = false)),
    _Rule('AMC', (m, r) => AtReply([hex2(_activityCount())])),
    _Rule('AMT($_hx{2})', (m, r) => _set(() => state.activityTimeout = _h(m))),
    _Rule('AR', (m, r) => _set(() => state.receiveAddress = null)),
    _Rule('AT([012])', (m, r) => _set(() => state.timing = AdaptiveTiming.values[int.parse(m.group(1)!)])),
    _Rule('BD', (m, r) => AtReply([_bufferDump()])),
    _Rule('BI', (m, r) => _ok),
    _Rule('DP', (m, r) => AtReply([state.describeProtocol()])),
    _Rule('DPN', (m, r) => AtReply([state.describeProtocolNumber()])),
    _Rule('H([01])', (m, r) => _set(() => state.headers = _b(m))),
    _Rule('MA', (m, r) => const AtMonitor()),
    _Rule('MR($_hx{2})', (m, r) => AtMonitor(receiver: _h(m))),
    _Rule('MT($_hx{2})', (m, r) => AtMonitor(transmitter: _h(m))),
    _Rule('PC', (m, r) => _ok),
    _Rule('R([01])', (m, r) => _set(() => state.responses = _b(m))),
    _Rule('RA($_hx{2})', (m, r) => _set(() => state.receiveAddress = _h(m))),
    _Rule('SR($_hx{2})', (m, r) => _set(() => state.receiveAddress = _h(m))),
    _Rule('S([01])', (m, r) => _set(() => state.spaces = _b(m))),
    _Rule('SH($_hx{3})', (m, r) => _set(() => state.header = _h(m))),
    _Rule('SH($_hx{6})', (m, r) => _set(() => state.header = _h(m))),
    _Rule('SH($_hx{2})($_hx{6})', (m, r) => _set(() {
          state.priority29 = _h(m) & 0x1F;
          state.header = _h(m, 2);
        })),
    _Rule('SP00', (m, r) => _set(() => state.setProtocol(0, auto: true, save: true))),
    _Rule('SP([0-9A-C])', (m, r) => _set(() {
          final p = _h(m);
          state.setProtocol(p, auto: p == 0, save: p != 0);
        })),
    _Rule('SPA([0-9A-C])', (m, r) => _set(() => state.setProtocol(_h(m), auto: true, save: true))),
    _Rule('TP([0-9A-C])', (m, r) => _set(() {
          final p = _h(m);
          state.setProtocol(p, auto: p == 0, save: false);
        })),
    _Rule('TPA([0-9A-C])', (m, r) => _set(() => state.setProtocol(_h(m), auto: true, save: false))),
    _Rule('SS', (m, r) => _ok),
    _Rule('ST($_hx{2})', (m, r) => _set(() => state.timeoutHex = _h(m) == 0 ? 0x32 : _h(m))),
    _Rule('TA($_hx{2})', (m, r) => _set(() => state.testerAddress = _h(m))),
    // ---- CAN ----
    _Rule('CAF([01])', (m, r) => _set(() => state.caf = _b(m))),
    _Rule('CEA', (m, r) => _set(() => state.extendedAddress = null)),
    _Rule('CEA($_hx{2})', (m, r) => _set(() => state.extendedAddress = _h(m))),
    _Rule('CF($_hx{3}|$_hx{8})', (m, r) => _set(() => state.filterId = _h(m))),
    _Rule('CFC([01])', (m, r) => _set(() => state.autoFlowControl = _b(m))),
    _Rule('CM($_hx{3}|$_hx{8})', (m, r) => _set(() => state.maskId = _h(m))),
    _Rule('CP($_hx{2})', (m, r) => _set(() => state.priority29 = _h(m) & 0x1F)),
    _Rule('CRA', (m, r) => _set(() {
          state.craId = null;
          state.filterId = null;
          state.maskId = null;
        })),
    _Rule('CRA($_hx{3}|$_hx{8})', (m, r) => _set(() => state.craId = _h(m))),
    _Rule('CS', (m, r) => AtReply(['T:${hex2(state.txErrors)} R:${hex2(state.rxErrors)}'])),
    _Rule('CSM[01]', (m, r) => _ok),
    _Rule('D([01])', (m, r) => _set(() => state.dlc = _b(m))),
    _Rule('FCSM([0-9])', (m, r) => _setFlowMode(int.parse(m.group(1)!))),
    _Rule('FCSH($_hx{3}|$_hx{8})', (m, r) => _set(() => state.flowHeader = _h(m))),
    _Rule('FCSD((?:$_hx{2}){1,5})', (m, r) => _set(() {
          final s = m.group(1)!;
          state.flowData = [
            for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
          ];
        })),
    _Rule('PB$_hx{2}$_hx{2}', (m, r) => _ok),
    _Rule('RTR', (m, r) => const AtRtr()),
    _Rule('V([01])', (m, r) => _set(() => state.variableDlc = _b(m))),
    // ---- J1850 / ISO / J1939（CAN 以外）: 設定は受け付け、実行は ? ----
    _Rule('IFR[012HS]', (m, r) => _ok),
    _Rule('IB(?:10|48|96)', (m, r) => _ok),
    _Rule('IIA$_hx{2}', (m, r) => _ok),
    _Rule('KW[01]', (m, r) => _ok),
    _Rule('SW$_hx{2}', (m, r) => _ok),
    _Rule('WM(?:$_hx{2}){1,6}', (m, r) => _ok),
    _Rule('J[ES]', (m, r) => _ok),
    _Rule('JHF[01]', (m, r) => _ok),
    _Rule('JTM[15]', (m, r) => _ok),
    _Rule('FI', (m, r) => _q),
    _Rule('SI', (m, r) => _q),
    _Rule('KW', (m, r) => _q),
    _Rule('DM1', (m, r) => _q),
    _Rule('MP(?:$_hx{4}|$_hx{6})$_hx?', (m, r) => _q),
  ];

  AtOutcome _reset() {
    state.reset();
    return const AtReset();
  }

  AtOutcome _storeDeviceId(String raw) {
    if (state.deviceId != null) return _q; // 一度設定したら変更できない（p.26）
    final m = RegExp(r'@3\s?(.*)$').firstMatch(raw);
    final id = m?.group(1) ?? '';
    if (id.length != 12) return _q;
    state.deviceId = id;
    return _ok;
  }

  Iterable<int> _ppRange(int n) => n == 0xFF ? List.generate(0x30, (i) => i) : [n];

  List<String> _ppSummary() {
    String item(int n) {
      final value = state.ppValues[n] ?? (n == 0x26 ? 0x00 : 0xFF);
      return '${hex2(n)}:${hex2(value)} ${state.ppEnabled.contains(n) ? 'N' : 'F'}';
    }

    return [
      for (var row = 0; row < 0x30; row += 4)
        [for (var n = row; n < row + 4; n++) item(n)].join('  '),
    ];
  }

  AtOutcome _calibrate(int hundredths) {
    state.voltageOffset = hundredths == 0 ? null : hundredths / 100 - voltage();
    return _ok;
  }

  int _activityCount() {
    final last = state.lastActivity;
    if (last == null) return 0xFF;
    final ticks = clock.now().difference(last).inMicroseconds ~/ 655360;
    return math.min(0xFF, math.max(0, ticks));
  }

  /// 長さ 1 バイト + OBD バッファ 12 バイト（p.12）。ID の格納方法は近似。
  String _bufferDump() {
    final f = state.lastFrame;
    final content = f == null
        ? <int>[]
        : [
            ...(f.extended
                ? [(f.id >> 24) & 0xFF, (f.id >> 16) & 0xFF, (f.id >> 8) & 0xFF, f.id & 0xFF]
                : [(f.id >> 8) & 0x07, f.id & 0xFF]),
            ...f.data,
          ];
    final length = math.min(12, content.length);
    final buffer = [...content.take(12), ...List.filled(12 - length, 0)];
    return [length, ...buffer].map(hex2).join(' ');
  }

  AtOutcome _setFlowMode(int mode) {
    if (mode > 2) return _q;
    if (mode == 1 && (state.flowHeader == null || state.flowData == null)) return _q;
    if (mode == 2 && state.flowData == null) return _q;
    state.flowMode = mode;
    return _ok;
  }
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/elm327/at_commands_test.dart`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/elm327/at_commands.dart test/elm327/at_commands_test.dart
git commit -m "feat: AT コマンド全項目（データシート p.9-10）を表で実装

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: ElmSession（非同期の要求処理）と旧テストの移行

**Files:**
- Create: `lib/elm327/elm_session.dart`
- Create: `test/support/elm_harness.dart`
- Test: `test/elm327/elm_session_test.dart`, `test/elm327/legacy_behavior_test.dart`

**Interfaces:**
- Consumes: Task 1〜9 のすべて（`VirtualCanBus`, `BusEvent`, `CanFrame`, `frameType`, `flowControl`, `Reassembler`, `FaultInjector`, `ElmErrorKind`, `ElmState`, `AdaptiveTiming`, `LineAssembler`, `ResponseFormatter`, `AtCommands` と各 `AtOutcome`, `parseHexBytes`, `Ecu`, `EcuProfile`, `ObdServices`, `UdsServices`）
- Produces:
  - `enum SessionMode { idle, busy, monitoring, lowPower }`
  - `class ElmSession { ElmSession({required VirtualCanBus bus, required FaultInjector faults, required double Function() voltage}); final ElmState state; void input(List<int> bytes); Stream<List<int>> get output; SessionMode get mode; void dispose(); static const adaptiveWait = Duration(milliseconds: 50); static const pendingWait = Duration(milliseconds: 5000); }`
  - `output` は同期のブロードキャスト。監視（MA/MR/MT）の中身は Task 11 で足す（この Task では `AtMonitor` を受けたら monitoring に入り、何か受信したら `STOPPED` で抜けるところまで）。
  - テスト用 `class ElmHarness`（`test/support/elm_harness.dart`）: `ElmHarness(FakeAsync async, {bool transmission = false})`, `String send(String cmd)`, `String sendRaw(String raw, {bool untilPrompt = false, Duration elapse = Duration.zero})`, `void quiet()`, フィールド `bus`, `vehicle`, `engineProfile`, `transmissionProfile`, `faultConfig`, `obd`, `session`

- [ ] **Step 1: テスト用ハーネスを書く**

`test/support/elm_harness.dart`:

```dart
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/ecu/ecu.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/ecu/obd_services.dart';
import 'package:elm327emu/ecu/uds_services.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

/// 仮想バス・ECU 2 台・セッション 1 つの組み立て。fakeAsync の中で使う。
class ElmHarness {
  ElmHarness(this.async, {bool transmission = false, int seed = 1}) {
    transmissionProfile.enabled = transmission;
    faults = FaultInjector(faultConfig, random: Random(seed));
    obd = ObdServices(vehicle);
    obd.addConfirmedDtc(engineProfile, 'P0301');
    for (final p in [engineProfile, transmissionProfile]) {
      bus.attach(Ecu(profile: p, bus: bus, obd: obd, uds: UdsServices(), faults: faults));
    }
    session = newSession();
  }

  final FakeAsync async;
  final VirtualCanBus bus = VirtualCanBus();
  final VehicleState vehicle = VehicleState.defaults();
  final EcuProfile engineProfile = EcuProfile.engine();
  final EcuProfile transmissionProfile = EcuProfile.transmission();
  final FaultConfig faultConfig = FaultConfig();
  late final FaultInjector faults;
  late final ObdServices obd;
  late final ElmSession session;
  final StringBuffer _out = StringBuffer();

  ElmSession newSession({StringBuffer? sink}) {
    final s = ElmSession(bus: bus, faults: faults, voltage: () => vehicle.batteryVoltage);
    s.output.listen((b) => (sink ?? _out).write(String.fromCharCodes(b)));
    return s;
  }

  String get all => _out.toString();

  /// [cmd] + CR を送り、'>' が出るまで（最大 20 秒ぶん）時間を進め、その間の出力を返す。
  String send(String cmd) => sendRaw('$cmd\r', untilPrompt: true);

  String sendRaw(String raw, {bool untilPrompt = false, Duration elapse = Duration.zero}) {
    final start = _out.length;
    session.input(raw.codeUnits);
    if (untilPrompt) {
      for (var i = 0; i < 20000 && !_out.toString().substring(start).endsWith('>'); i++) {
        async.elapse(const Duration(milliseconds: 1));
      }
    } else {
      async.elapse(elapse);
    }
    return _out.toString().substring(start);
  }

  /// エコーを切り、0100 でプロトコルを確定させる（以後 SEARCHING... が出ない）。
  void quiet() {
    send('ATE0');
    send('0100');
  }
}
```

- [ ] **Step 2: 失敗するテストを書く**

`test/elm327/elm_session_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import '../support/elm_harness.dart';

void t(String name, void Function(ElmHarness h, FakeAsync async) body,
    {bool transmission = false}) {
  test(name, () => fakeAsync((async) => body(ElmHarness(async, transmission: transmission), async)));
}

Duration timed(FakeAsync async, void Function() fn) {
  final start = async.elapsed;
  fn();
  return async.elapsed - start;
}

void main() {
  group('出力の形', () {
    t('ATZ はエコー + 空行 2 つ + ID', (h, a) {
      expect(h.send('ATZ'), 'ATZ\r\r\rELM327 v1.5\r\r>');
    });
    t('ATE0 の応答まではエコーする', (h, a) {
      expect(h.send('ATE0'), 'ATE0\rOK\r\r>');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
    t('L1 は CRLF', (h, a) {
      h.send('ATE0');
      h.send('ATL1');
      expect(h.send('ATI'), 'ELM327 v1.5\r\n\r\n>');
    });
    t('小文字とスペースも受け付ける', (h, a) {
      h.send('ATE0');
      expect(h.send('at i'), 'ELM327 v1.5\r\r>');
      expect(h.send('01 0c'), 'SEARCHING...\r41 0C 0C 80 \r\r>');
    });
  });

  group('プロトコル確定', () {
    t('最初の OBD 要求だけ SEARCHING...、確定後の DPN は A6', (h, a) {
      h.send('ATE0');
      expect(h.send('0100'), 'SEARCHING...\r41 00 BE 3F A0 13 \r\r>');
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r\r>');
      expect(h.send('ATDPN'), 'A6\r\r>');
      expect(h.send('ATDP'), 'AUTO, ISO 15765-4 (CAN 11/500)\r\r>');
    });
    t('ATSP6（固定）では SEARCHING... を出さない', (h, a) {
      h.send('ATE0');
      h.send('ATSP6');
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
      expect(h.send('ATDPN'), '6\r\r>');
    });
    t('検索中に応答がなければ UNABLE TO CONNECT（旧: NO DATA）', (h, a) {
      h.send('ATE0');
      expect(h.send('01FF'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
      expect(h.send('ATDPN'), 'A0\r\r>');
    });
    t('CAN 以外を固定すると 3〜5 は BUS INIT: ...ERROR、1 は NO DATA', (h, a) {
      h.send('ATE0');
      h.send('ATSP3');
      expect(h.send('0100'), 'BUS INIT: ...ERROR\r\r>');
      h.send('ATSP1');
      expect(h.send('0100'), 'NO DATA\r\r>');
    });
    t('ATSP7 は 29bit、ヘッダ表示は 4 バイト', (h, a) {
      h.send('ATE0');
      h.send('ATSP7');
      h.send('ATH1');
      expect(h.send('010C'), '18 DA F1 10 04 41 0C 0C 80 00 00 00 \r\r>');
    });
  });

  group('応答の形', () {
    t('H1: ID・PCI・8 バイト', (h, a) {
      h.quiet();
      h.send('ATH1');
      expect(h.send('010C'), '7E8 04 41 0C 0C 80 00 00 00 \r\r>');
    });
    t('VIN（H0）は総バイト数と連番', (h, a) {
      h.quiet();
      expect(h.send('0902'),
          '014\r0: 49 02 01 57 41 55 \r1: 5A 5A 5A 38 4B 39 41 \r2: 41 30 30 30 30 30 30 \r\r>');
    });
    t('VIN（H1）は 1 フレーム 1 行', (h, a) {
      h.quiet();
      h.send('ATH1');
      expect(h.send('0902'),
          '7E8 10 14 49 02 01 57 41 55 \r7E8 21 5A 5A 5A 38 4B 39 41 \r7E8 22 41 30 30 30 30 30 30 \r\r>');
    });
    t('CFC0 では FC を送らないので最初のフレームで止まる', (h, a) {
      h.quiet();
      h.send('ATCFC0');
      expect(h.send('0902'), '014\r0: 49 02 01 57 41 55 \r\r>');
    });
    t('複数 PID', (h, a) {
      h.quiet();
      expect(h.send('010C0D05'), '41 0C 0C 80 0D 00 05 7D \r\r>');
    });
    t('トランスミッション有効なら 2 行', (h, a) {
      h.quiet();
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r41 00 80 00 00 01 \r\r>');
    }, transmission: true);
    t('Mode 22: ECU 指定で応答、全 ECU 宛ては NO DATA', (h, a) {
      h.quiet();
      expect(h.send('22F190'), 'NO DATA\r\r>');
      h.send('ATSH7E0');
      expect(h.send('22F190'),
          '014\r0: 62 F1 90 57 41 55 \r1: 5A 5A 5A 38 4B 39 41 \r2: 41 30 30 30 30 30 30 \r\r>');
      expect(h.send('221234'), '7F 22 31 \r\r>');
      expect(h.send('1003'), '7F 10 11 \r\r>');
    });
    t('未対応 PID は NO DATA', (h, a) {
      h.quiet();
      expect(h.send('01FF'), 'NO DATA\r\r>');
    });
    t('CRA で 7E9 だけ受けるとエンジンの応答は NO DATA', (h, a) {
      h.quiet();
      h.send('ATCRA7E9');
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
  });

  group('行の解釈', () {
    t('16 進以外・末尾 0・長すぎは ?', (h, a) {
      h.quiet();
      expect(h.send('0XYZ'), '?\r\r>');
      expect(h.send('010'), '?\r\r>');
      expect(h.send('01000C0D050B0E0F'), '?\r\r>'); // 8 バイト（CAF1 は 7 まで）
    });
    t('CAF0 では 8 バイトまで送れる（p.45）', (h, a) {
      h.quiet();
      h.send('ATCAF0');
      expect(h.send('02010C0000000000'), '04 41 0C 0C 80 00 00 00 \r\r>');
    });
    t('空行は直前のコマンドを繰り返す', (h, a) {
      h.quiet();
      h.send('010C');
      h.vehicle.rpm = 2150;
      expect(h.send(''), '41 0C 21 98 \r\r>');
    });
    t('直前のコマンドがない空行は > のみ', (h, a) {
      h.send('ATE0');
      h.session.state.lastCommand = null;
      expect(h.send(''), '>');
    });
    t('ELM327 の分からない入力（DEL 2 つ）は ?（python-OBD の速度判定）', (h, a) {
      h.send('ATE0');
      expect(h.sendRaw('\x7F\x7F\r', untilPrompt: true), '?\r\r>');
    });
  });

  group('タイミング', () {
    t('応答数指定 1 はエンジンの応答（8ms）ですぐ返る', (h, a) {
      h.quiet();
      final d = timed(a, () => expect(h.send('010C1'), '41 0C 0C 80 \r\r>'));
      expect(d, lessThan(const Duration(milliseconds: 12)));
    });
    t('指定なしは最後の応答から 50ms 待つ（AT1）', (h, a) {
      h.quiet();
      final d = timed(a, () => h.send('010C'));
      expect(d.inMilliseconds, inInclusiveRange(58, 60));
    });
    t('AT0 は ST（200ms）まで待つ', (h, a) {
      h.quiet();
      h.send('ATAT0');
      final d = timed(a, () => h.send('010C'));
      expect(d.inMilliseconds, inInclusiveRange(208, 210));
    });
    t('応答がなければ ST で NO DATA、ST19 なら 100ms', (h, a) {
      h.quiet();
      h.send('ATST19');
      final d = timed(a, () => expect(h.send('01FF'), 'NO DATA\r\r>'));
      expect(d.inMilliseconds, inInclusiveRange(100, 102));
    });
    t('R0 は応答を待たない', (h, a) {
      h.quiet();
      h.send('ATR0');
      final d = timed(a, () => expect(h.send('010C'), '\r>'));
      expect(d, Duration.zero);
    });
  });

  group('STOPPED と入力の割り込み', () {
    t('応答待ちに文字が届くと STOPPED', (h, a) {
      h.quiet();
      final out = h.sendRaw('010C\rX', elapse: const Duration(milliseconds: 100));
      expect(out, 'STOPPED\r\r>');
      expect(h.session.mode, SessionMode.idle);
    });
    t('LF は応答待ちを止めない（Review Focus 1）', (h, a) {
      h.quiet();
      expect(h.sendRaw('010C\r\n', untilPrompt: true), '41 0C 0C 80 \r\r>');
    });
    t('分割して届いたコマンドを 1 行として扱う（Review Focus 2）', (h, a) {
      h.quiet();
      h.sendRaw('01', elapse: const Duration(milliseconds: 5));
      expect(h.sendRaw('0C\r', untilPrompt: true), '41 0C 0C 80 \r\r>');
    });
    t('AT 2 つを 1 回で送ると両方処理する', (h, a) {
      expect(h.sendRaw('ATE0\rATH1\r', elapse: const Duration(milliseconds: 1)),
          'ATE0\rOK\r\r>OK\r\r>');
    });
    t('LP の後は何を送っても応答せず、その次から普通に動く', (h, a) {
      h.send('ATE0');
      expect(h.send('ATLP'), 'OK\r\r>');
      expect(h.session.mode, SessionMode.lowPower);
      expect(h.sendRaw(' ', elapse: const Duration(milliseconds: 10)), '');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
  });

  group('障害', () {
    t('イグニッション OFF: 検索中は UNABLE TO CONNECT、確定後は CAN ERROR', (h, a) {
      h.send('ATE0');
      h.faultConfig.ignitionOff = true;
      expect(h.send('0100'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
      h.faultConfig.ignitionOff = false;
      h.send('0100');
      h.faultConfig.ignitionOff = true;
      expect(h.send('0100'), 'CAN ERROR\r\r>');
    });
    t('ECU 無応答は NO DATA', (h, a) {
      h.quiet();
      h.faultConfig.silentEcus.add('engine');
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
    t('遅延が ST を超えると NO DATA、超えなければ遅れて返る', (h, a) {
      h.quiet();
      h.faultConfig.delayMs = 350;
      expect(h.send('010C'), 'NO DATA\r\r>');
      h.faultConfig.delayMs = 100;
      final d = timed(a, () => expect(h.send('010C1'), '41 0C 0C 80 \r\r>'));
      expect(d.inMilliseconds, inInclusiveRange(108, 110));
    });
    t('欠落 100% は NO DATA', (h, a) {
      h.quiet();
      h.faultConfig.dropPercent = 100;
      expect(h.send('010C'), 'NO DATA\r\r>');
    });
    t('応答保留: 7F 01 78 を表示し、1 秒後の本応答まで待つ', (h, a) {
      h.quiet();
      h.send('ATSH7E0');
      h.faultConfig.responsePending = true;
      final d = timed(a, () => expect(h.send('010C'), '7F 01 78 \r41 0C 0C 80 \r\r>'));
      expect(d.inMilliseconds, inInclusiveRange(1058, 1060));
    });
    t('途中欠落: 最初のフレームだけ表示して終わる', (h, a) {
      h.quiet();
      h.faultConfig.truncateMultiFrame = true;
      expect(h.send('0902'), '014\r0: 49 02 01 57 41 55 \r\r>');
    });
    t('エラー（次の 1 回）と CS のカウンタ', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.canError
        ..errorArmed = true;
      expect(h.send('010C'), 'CAN ERROR\r\r>');
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
      expect(h.send('ATCS'), 'T:01 R:00\r\r>');
    });
    t('エラー（常に）は解除するまで続く', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.bufferFull
        ..errorTrigger = ErrorTrigger.always
        ..errorArmed = true;
      expect(h.send('010C'), 'BUFFER FULL\r\r>');
      expect(h.send('010C'), 'BUFFER FULL\r\r>');
      h.faultConfig.errorArmed = false;
      expect(h.send('010C'), '41 0C 0C 80 \r\r>');
    });
    t('<DATA ERROR は最後のデータ行の横に付く', (h, a) {
      h.quiet();
      h.faultConfig
        ..error = ElmErrorKind.dataErrorMark
        ..errorArmed = true;
      expect(h.send('010C'), '41 0C 0C 80 <DATA ERROR\r\r>');
    });
    t('LV RESET は AT 設定を戻す', (h, a) {
      h.quiet();
      h.send('ATH1');
      h.faultConfig
        ..error = ElmErrorKind.lvReset
        ..errorArmed = true;
      expect(h.send('010C'), 'LV RESET\r\r>');
      expect(h.session.state.headers, isFalse);
      expect(h.session.state.echo, isTrue);
    });
    t('応答待ち中に障害を切り替えても必ず終わる（Review Focus 3）', (h, a) {
      h.quiet();
      h.faultConfig.delayMs = 100;
      final out = StringBuffer();
      out.write(h.sendRaw('010C\r', elapse: const Duration(milliseconds: 50)));
      h.faultConfig.silentEcus.add('engine');
      out.write(h.sendRaw('', elapse: const Duration(milliseconds: 300)));
      expect(out.toString(), 'NO DATA\r\r>');
      expect(h.session.mode, SessionMode.idle);
    });
  });

  t('BD は最後に受信したフレーム', (h, a) {
    h.quiet();
    h.send('010C');
    expect(h.send('ATBD'), '0A 07 E8 04 41 0C 0C 80 00 00 00 00 00\r\r>');
  });

  t('dispose 後は出力しない（Review Focus 4）', (h, a) {
    h.quiet();
    final before = h.all.length;
    h.session.input('010C\r'.codeUnits);
    h.session.dispose();
    a.elapse(const Duration(seconds: 1));
    expect(h.all.length, before);
    h.session.input('ATI\r'.codeUnits); // 例外にならない
  });

  t('監視中は何か受信すると STOPPED（中身は Task 11）', (h, a) {
    h.quiet();
    expect(h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 5)), '');
    expect(h.session.mode, SessionMode.monitoring);
    expect(h.sendRaw('X', elapse: const Duration(milliseconds: 1)), 'STOPPED\r\r>');
  });
}
```

`test/elm327/legacy_behavior_test.dart`（旧 `elm327_engine_test` / `at_command_handler_test` / `obd_command_handler_test` の内容を新 API で確かめる。期待値を変えたものは「旧:」で残す）:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import '../support/elm_harness.dart';

void t(String name, void Function(ElmHarness h) body) {
  test(name, () => fakeAsync((async) => body(ElmHarness(async))));
}

void main() {
  group('旧 elm327_engine_test', () {
    t('ATZ: エコー + 識別子 + プロンプト（旧: 空行なし）', (h) {
      expect(h.send('ATZ'), 'ATZ\r\r\rELM327 v1.5\r\r>');
    });
    t('echo OFF 後はエコーしない', (h) {
      h.send('ATE0');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
    t('OBD 応答にプロンプト', (h) {
      h.quiet();
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '41 0C 1A F8 \r\r>');
    });
    t('linefeed ON は CRLF', (h) {
      h.send('ATE0');
      h.send('ATL1');
      expect(h.send('ATI'), 'ELM327 v1.5\r\n\r\n>');
    });
  });

  group('旧 at_command_handler_test', () {
    t('ATZ でリセット（エコーが戻る）', (h) {
      h.send('ATE0');
      h.send('ATZ');
      expect(h.session.state.echo, isTrue);
    });
    t('ATE0 / ATH1 / ATSP6', (h) {
      expect(h.send('ATE0'), 'ATE0\rOK\r\r>');
      expect(h.send('ATH1'), 'OK\r\r>');
      expect(h.session.state.headers, isTrue);
      expect(h.send('ATSP6'), 'OK\r\r>');
      expect(h.session.state.protocol, 6);
    });
    t('ATDPN（旧: 6 → 起動直後は A0）', (h) {
      h.send('ATE0');
      expect(h.send('ATDPN'), 'A0\r\r>');
    });
    t('ATI / ATRV', (h) {
      h.send('ATE0');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
      expect(h.send('ATRV'), '12.4V\r\r>');
    });
    t('未知 AT は ?', (h) {
      h.send('ATE0');
      expect(h.send('ATXYZ'), '?\r\r>');
    });
    t('ATSP（引数なし）は ?（旧: OK）', (h) {
      h.send('ATE0');
      expect(h.send('ATSP'), '?\r\r>');
    });
    t('ATSP0 は自動（旧: protocol = 6）', (h) {
      h.send('ATE0');
      h.send('ATSP0');
      expect(h.session.state.autoSearch, isTrue);
      h.send('0100');
      expect(h.send('ATDPN'), 'A6\r\r>');
    });
    t('ATSPA6 は自動・6 から', (h) {
      h.send('ATE0');
      expect(h.send('ATSPA6'), 'OK\r\r>');
      expect(h.session.state.protocol, 6);
      expect(h.session.state.autoSearch, isTrue);
    });
    t('ATS0 でスペースなし（回帰防止）', (h) {
      h.send('ATE0');
      expect(h.send('ATS0'), 'OK\r\r>');
      expect(h.session.state.spaces, isFalse);
    });
  });

  group('旧 obd_command_handler_test', () {
    t('010C / 010D / 0105', (h) {
      h.quiet();
      h.vehicle
        ..rpm = 1726
        ..speedKmh = 60
        ..coolantTempC = 85;
      expect(h.send('010C'), '41 0C 1A F8 \r\r>');
      expect(h.send('010D'), '41 0D 3C \r\r>');
      expect(h.send('0105'), '41 05 7D \r\r>');
    });
    t('spaces off で連結', (h) {
      h.quiet();
      h.send('ATS0');
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '410C1AF8\r\r>');
    });
    t('headers on（旧: パディングなし）', (h) {
      h.quiet();
      h.send('ATH1');
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '7E8 04 41 0C 1A F8 00 00 00 \r\r>');
    });
    t('0100 ビットマップ（旧: 18 1B 80 01）', (h) {
      h.quiet();
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r\r>');
    });
    t('03 で DTC、04 で消去', (h) {
      h.quiet();
      expect(h.send('03'), '43 01 03 01 \r\r>');
      expect(h.send('04'), '44 \r\r>');
      expect(h.engineProfile.confirmedDtcs, isEmpty);
    });
    t('0902 VIN は複数フレーム', (h) {
      h.quiet();
      expect(h.send('0902').split('\r').first, matches(RegExp(r'^[0-9A-F]{3}$')));
    });
    t('未対応 PID は NO DATA', (h) {
      h.quiet();
      expect(h.send('01FF'), 'NO DATA\r\r>');
    });
    t('初期化前の未対応 PID（旧: SEARCHING... + NO DATA）', (h) {
      h.send('ATE0');
      expect(h.send('01FF'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
    });
    t('初期化前は SEARCHING... が先頭、以後は確立', (h) {
      h.send('ATE0');
      expect(h.send('010C').split('\r').first, 'SEARCHING...');
      expect(h.session.state.established, 6);
    });
  });
}
```

- [ ] **Step 3: 失敗を確認する**

Run: `flutter test test/elm327/elm_session_test.dart test/elm327/legacy_behavior_test.dart`
Expected: FAIL（`elm_session.dart` がない）

- [ ] **Step 4: 実装する**

`lib/elm327/elm_session.dart`:

```dart
import 'dart:async';

import 'package:clock/clock.dart';

import '../can/can_frame.dart';
import '../can/fault_injector.dart';
import '../can/iso_tp.dart';
import '../can/virtual_can_bus.dart';
import '../util/hex.dart';
import 'at_commands.dart';
import 'elm_state.dart';
import 'line_assembler.dart';
import 'response_formatter.dart';

enum SessionMode { idle, busy, monitoring, lowPower }

class _Pending {
  _Pending({required this.expected, required this.searching, required this.dropped, required this.mark});
  final int? expected;
  final bool searching;
  final bool dropped;
  final ElmErrorKind? mark;
  final List<String> lines = [];
  int completed = 0;
  final Map<int, Reassembler> _reassemblers = {};
  Reassembler reassemblerFor(int id) => _reassemblers.putIfAbsent(id, Reassembler.new);
}

class _Monitor {
  const _Monitor(this.receiver, this.transmitter);
  final int? receiver;
  final int? transmitter;
}

/// 1 接続ぶんの ELM327。入力バイトを受け、AT を処理し、OBD/UDS 要求を仮想バスへ送る。
class ElmSession {
  ElmSession({required this.bus, required this.faults, required double Function() voltage}) {
    at = AtCommands(state, voltage: voltage, ignitionOn: () => !faults.config.ignitionOff);
    formatter = ResponseFormatter(state);
    _unlisten = bus.listen(_onBusEvent);
  }

  final VirtualCanBus bus;
  final FaultInjector faults;
  final ElmState state = ElmState();
  late final AtCommands at;
  late final ResponseFormatter formatter;

  static const adaptiveWait = Duration(milliseconds: 50);
  static const pendingWait = Duration(milliseconds: 5000);

  final LineAssembler _assembler = LineAssembler();
  final StreamController<List<int>> _out = StreamController.broadcast(sync: true);
  late final void Function() _unlisten;
  SessionMode _mode = SessionMode.idle;
  _Pending? _pending;
  _Monitor? _monitor;
  Timer? _timer;
  bool _disposed = false;

  Stream<List<int>> get output => _out.stream;
  SessionMode get mode => _mode;

  String get _eol => state.linefeed ? '\r\n' : '\r';

  void input(List<int> bytes) {
    if (_disposed) return;
    for (final b in bytes) {
      switch (_mode) {
        case SessionMode.lowPower:
          _mode = SessionMode.idle; // 起こした文字は捨てる
        case SessionMode.busy:
        case SessionMode.monitoring:
          if (b == 0x0A || b == 0x00) continue; // 変更点 9
          _stop();
        case SessionMode.idle:
          for (final line in _assembler.addBytes([b])) {
            _processLine(line);
          }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _unlisten();
    _out.close();
  }

  void _emit(String s) {
    if (!_disposed) _out.add(s.codeUnits);
  }

  void _finish(List<String> lines) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _monitor = null;
    _mode = SessionMode.idle;
    _emit('${lines.map((l) => '$l$_eol').join()}$_eol>');
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _monitor = null;
    _mode = SessionMode.idle;
    _emit('STOPPED$_eol$_eol>');
  }

  void _processLine(String raw) {
    if (state.echo) _emit('$raw\r');
    var text = raw.toUpperCase().replaceAll(' ', '');
    if (text.isEmpty) {
      final last = state.lastCommand;
      if (last == null) {
        _emit('>');
        return;
      }
      text = last;
    } else {
      state.lastCommand = text;
    }
    if (text.startsWith('AT')) {
      _handleAt(text.substring(2), raw);
    } else {
      _handleRequest(text);
    }
  }

  void _handleAt(String body, String raw) {
    switch (at.handle(body, raw: raw)) {
      case AtReply(:final lines):
        _finish(lines);
      case AtReset():
        formatter.reset();
        _finish(const ['', '', elmId]);
      case AtLowPower():
        _finish(const ['OK']);
        _mode = SessionMode.lowPower;
      case AtMonitor(:final receiver, :final transmitter):
        formatter.reset();
        _monitor = _Monitor(receiver, transmitter);
        _mode = SessionMode.monitoring;
      case AtRtr():
        bus.transmit(CanFrame(state.txId, const [], extended: state.is29bit, rtr: true), sender: this);
        _finish(const []);
    }
  }

  void _handleRequest(String text) {
    var hexText = text;
    int? expected;
    if (hexText.length.isOdd) {
      final n = int.tryParse(hexText[hexText.length - 1], radix: 16);
      if (n == null || n == 0) {
        _finish(const ['?']);
        return;
      }
      expected = n;
      hexText = hexText.substring(0, hexText.length - 1);
    }
    final payload = parseHexBytes(hexText);
    final maxLength = (state.caf ? 7 : 8) - (state.extendedAddress == null ? 0 : 1);
    if (payload == null || payload.length > maxLength) {
      _finish(const ['?']);
      return;
    }

    final protocol = state.activeProtocol;
    if (!ElmState.isCanProtocol(protocol)) {
      _finish([protocol >= 3 && protocol <= 5 ? 'BUS INIT: ...ERROR' : 'NO DATA']);
      return;
    }
    final searching = state.autoSearch && state.established == null;
    if (searching) _emit('SEARCHING...$_eol');

    final error = faults.takeError();
    if (error != null) {
      state.txErrors++;
      if (!error.isMark) {
        if (error.resetsState) state.reset();
        _finish([error.text]);
        return;
      }
    }

    final data = <int>[
      if (state.extendedAddress != null) state.extendedAddress!,
      if (state.caf) payload.length,
      ...payload,
    ];
    final padded = state.variableDlc ? data : [...data, ...List.filled(8 - data.length, canPadByte)];
    final frame = CanFrame(state.txId, padded, extended: state.is29bit);
    state
      ..lastFrame = frame
      ..lastActivity = clock.now();
    formatter.reset();
    _mode = SessionMode.busy;
    _pending = _Pending(
      expected: expected,
      searching: searching,
      dropped: faults.rollDrop(),
      mark: error != null && error.isMark ? error : null,
    );
    bus.transmit(frame, sender: this);
    if (!state.responses) {
      _finish(const []);
      return;
    }
    _arm(state.timeout);
  }

  void _arm(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _complete);
  }

  void _onBusEvent(BusEvent e) {
    if (_disposed || identical(e.sender, this)) return;
    final f = e.frame;
    if (_mode == SessionMode.monitoring) {
      _onMonitorFrame(f);
      return;
    }
    final p = _pending;
    if (_mode != SessionMode.busy || p == null) return;
    if (p.dropped || !state.acceptsResponse(f)) return;
    state
      ..lastFrame = f
      ..lastActivity = clock.now();
    p.lines.addAll(formatter.frameLines(f));
    if (frameType(f.data) == FrameType.first && state.autoFlowControl) {
      bus.transmit(CanFrame(_flowControlId(f), flowControl(), extended: f.extended), sender: this);
    }
    final message = p.reassemblerFor(f.id).add(f.data);
    if (message != null) {
      if (message.length == 3 && message[0] == 0x7F && message[2] == 0x78) {
        _arm(pendingWait); // 応答保留（未確認 4）
        return;
      }
      p.completed++;
      final expected = p.expected;
      if (expected != null && p.completed >= expected) {
        _complete();
        return;
      }
    }
    final wait = state.timing == AdaptiveTiming.off || state.timeout < adaptiveWait
        ? state.timeout
        : adaptiveWait;
    _arm(wait);
  }

  /// 監視の中身は Task 11 で足す。
  void _onMonitorFrame(CanFrame f) {}

  int _flowControlId(CanFrame f) => f.extended
      ? (f.id & 0xFFFF0000) | ((f.id & 0xFF) << 8) | ((f.id >> 8) & 0xFF)
      : f.id - 8;

  void _complete() {
    final p = _pending;
    if (p == null) return;
    var lines = List<String>.of(p.lines);
    if (lines.isEmpty) {
      lines = [
        p.searching
            ? 'UNABLE TO CONNECT'
            : (faults.config.ignitionOff ? 'CAN ERROR' : 'NO DATA'),
      ];
    } else {
      if (p.searching) state.established = state.activeProtocol;
      final mark = p.mark;
      if (mark != null) {
        final last = lines.removeLast();
        lines.add(last.endsWith(' ') ? '$last${mark.text}' : '$last ${mark.text}');
      }
    }
    _finish(lines);
  }
}
```

- [ ] **Step 5: 通ることを確認する**

Run: `flutter test test/elm327/elm_session_test.dart test/elm327/legacy_behavior_test.dart && flutter test`
Expected: PASS（全体も PASS）

- [ ] **Step 6: わざと壊して落ちることを確かめる**

次の 3 つを 1 つずつ一時的に入れ、`flutter test test/elm327/elm_session_test.dart` が該当テストで FAIL することを確認してから元に戻す:
1. `_onBusEvent` の FC 送信（`bus.transmit(CanFrame(_flowControlId(f) …`）をコメントアウト → 「VIN（H0）は総バイト数と連番」が FAIL
2. `input` の `if (b == 0x0A || b == 0x00) continue;` を消す → 「LF は応答待ちを止めない」が FAIL
3. `_complete` の `p.searching ? 'UNABLE TO CONNECT' :` を `'NO DATA'` に変える → 「検索中に応答がなければ UNABLE TO CONNECT」が FAIL

- [ ] **Step 7: コミット**

```bash
git add lib/elm327/elm_session.dart test/support/elm_harness.dart test/elm327/elm_session_test.dart test/elm327/legacy_behavior_test.dart
git commit -m "feat: ElmSession（非同期の要求処理・STOPPED・繰り返し・応答数指定・障害）と旧テストの移行

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: 監視（ATMA / MR / MT）と周期フレーム

**Files:**
- Create: `lib/can/periodic_traffic.dart`
- Modify: `lib/elm327/elm_session.dart`（`_onMonitorFrame` の中身）
- Test: `test/can/periodic_traffic_test.dart`, `test/elm327/monitor_test.dart`

**Interfaces:**
- Consumes: `VirtualCanBus`, `CanFrame`（Task 1）、`FaultInjector`（Task 6）、`pct255`, `temp40`（Task 4）、`VehicleState`（Task 3）、`ElmSession`（Task 10）、`ElmHarness`（Task 10）
- Produces:
  - `class PeriodicTraffic { PeriodicTraffic(VirtualCanBus bus, VehicleState vehicle, FaultInjector faults); void start(); void stop(); static const Set<int> ids = {0x0C9, 0x3E9, 0x4C1}; }`
  - フレームの中身（エミュレータ独自の形式）: `0C9`（20ms）= `[回転数×4 上位, 下位, スロットル%×255/100, 0,0,0,0,0]`、`3E9`（100ms）= `[車速×100 上位, 下位, 0,0,0,0,0,0]`、`4C1`（1000ms）= `[水温+40, 油温+40, 0,0,0,0,0,0]`。イグニッション OFF 中は流さない。

- [ ] **Step 1: 失敗するテストを書く**

`test/can/periodic_traffic_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/periodic_traffic.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  test('1 秒で 0C9 が 50 回、3E9 が 10 回、4C1 が 1 回', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final cfg = FaultConfig();
      final traffic = PeriodicTraffic(bus, VehicleState.defaults(), FaultInjector(cfg))..start();
      final ids = <int>[];
      bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(seconds: 1));
      expect(ids.where((i) => i == 0x0C9).length, 50);
      expect(ids.where((i) => i == 0x3E9).length, 10);
      expect(ids.where((i) => i == 0x4C1).length, 1);
      traffic.stop();
      ids.clear();
      async.elapse(const Duration(seconds: 1));
      expect(ids, isEmpty);
    });
  });

  test('中身は車両状態から作る', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final v = VehicleState.defaults()
        ..rpm = 2150
        ..speedKmh = 62
        ..throttlePct = 50;
      PeriodicTraffic(bus, v, FaultInjector(FaultConfig())).start();
      final frames = <CanFrame>[];
      bus.listen((e) => frames.add(e.frame));
      async.elapse(const Duration(seconds: 1));
      expect(frames.firstWhere((f) => f.id == 0x0C9).data, [0x21, 0x98, 0x80, 0, 0, 0, 0, 0]);
      expect(frames.firstWhere((f) => f.id == 0x3E9).data, [0x18, 0x38, 0, 0, 0, 0, 0, 0]);
      expect(frames.firstWhere((f) => f.id == 0x4C1).data, [0x7D, 0x82, 0, 0, 0, 0, 0, 0]);
    });
  });

  test('イグニッション OFF 中は流さない', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final cfg = FaultConfig()..ignitionOff = true;
      PeriodicTraffic(bus, VehicleState.defaults(), FaultInjector(cfg)).start();
      final ids = <int>[];
      bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(seconds: 1));
      expect(ids, isEmpty);
    });
  });
}
```

`test/elm327/monitor_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/periodic_traffic.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import '../support/elm_harness.dart';

void t(String name, void Function(ElmHarness h, FakeAsync a) body) {
  test(name, () => fakeAsync((a) {
        final h = ElmHarness(a);
        PeriodicTraffic(h.bus, h.vehicle, h.faults).start();
        body(h, a);
      }));
}

void main() {
  t('ATMA（H0）は周期フレームを生の 8 バイトで流す', (h, a) {
    h.send('ATE0');
    final out = h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 25));
    expect(out, '0C 80 1F 00 00 00 00 00 \r');
    expect(h.session.mode, SessionMode.monitoring);
  });

  t('ATMA（H1）は ID 付き、何か受信すると STOPPED', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    final out = h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 25));
    expect(out, '0C9 0C 80 1F 00 00 00 00 00 \r');
    expect(h.sendRaw('X', elapse: const Duration(milliseconds: 1)), 'STOPPED\r\r>');
    expect(h.sendRaw('', elapse: const Duration(milliseconds: 100)), '');
  });

  t('ATMT E9 は下位 8bit が E9 のフレームだけ', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    final out = h.sendRaw('ATMTE9\r', elapse: const Duration(milliseconds: 105));
    expect(out, '3E9 00 00 00 00 00 00 00 00 \r');
  });

  t('ほかのセッションの診断通信と FC も見える', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    h.send('ATCRA7E0');
    h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 1));
    final other = h.newSession(sink: StringBuffer());
    other.input('ATE0\rATSH7E0\r0902\r'.codeUnits);
    final out = h.sendRaw('', elapse: const Duration(milliseconds: 100));
    expect(out, '7E0 02 09 02 00 00 00 00 00 \r7E0 FC: 30 00 00 00 00 00 00 00 \r');
  });

  t('29bit プロトコル中は 11bit の周期フレームを出さない', (h, a) {
    h.send('ATE0');
    h.send('ATSP7');
    expect(h.sendRaw('ATMA\r', elapse: const Duration(milliseconds: 100)), '');
  });

  t('ATRTR は RTR フレームを送り、監視側（H1）には RTR と出る', (h, a) {
    h.send('ATE0');
    h.send('ATH1');
    h.sendRaw('ATMTDF\r', elapse: const Duration(milliseconds: 1));
    final other = h.newSession(sink: StringBuffer());
    other.input('ATE0\rATRTR\r'.codeUnits);
    final out = h.sendRaw('', elapse: const Duration(milliseconds: 5));
    expect(out, contains('7DF RTR\r'));
  });
}
```

（監視コマンドは `>` を出さないので、`send` ではなく `sendRaw` で送る。）

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/can/periodic_traffic_test.dart test/elm327/monitor_test.dart`
Expected: FAIL（`periodic_traffic.dart` がない、監視の出力が空）

- [ ] **Step 3: 実装する**

`lib/can/periodic_traffic.dart`:

```dart
import 'dart:async';

import '../ecu/pid_table.dart';
import '../vehicle/vehicle_state.dart';
import 'can_frame.dart';
import 'fault_injector.dart';
import 'virtual_can_bus.dart';

/// ATMA で見える周期フレーム。実在車種の形式ではなく、このエミュレータ独自の形式。
class PeriodicTraffic {
  PeriodicTraffic(this.bus, this.vehicle, this.faults);

  final VirtualCanBus bus;
  final VehicleState vehicle;
  final FaultInjector faults;

  static const Set<int> ids = {0x0C9, 0x3E9, 0x4C1};

  final List<Timer> _timers = [];

  void start() {
    stop();
    _timers
      ..add(Timer.periodic(const Duration(milliseconds: 20), (_) => _send(0x0C9, _engine)))
      ..add(Timer.periodic(const Duration(milliseconds: 100), (_) => _send(0x3E9, _speed)))
      ..add(Timer.periodic(const Duration(milliseconds: 1000), (_) => _send(0x4C1, _temps)));
  }

  void stop() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void _send(int id, List<int> Function() build) {
    if (faults.config.ignitionOff) return;
    bus.transmit(CanFrame(id, build()), sender: this);
  }

  List<int> _engine() {
    final r = (vehicle.rpm * 4).clamp(0, 0xFFFF).toInt();
    return [r >> 8, r & 0xFF, pct255(vehicle.throttlePct), 0, 0, 0, 0, 0];
  }

  List<int> _speed() {
    final s = (vehicle.speedKmh * 100).round().clamp(0, 0xFFFF).toInt();
    return [s >> 8, s & 0xFF, 0, 0, 0, 0, 0, 0];
  }

  List<int> _temps() =>
      [temp40(vehicle.coolantTempC), temp40(vehicle.oilTempC), 0, 0, 0, 0, 0, 0];
}
```

`lib/elm327/elm_session.dart` の `_onMonitorFrame` を置き換える:

```dart
  void _onMonitorFrame(CanFrame f) {
    final m = _monitor;
    if (m == null) return;
    if (!state.acceptsMonitor(f, receiver: m.receiver, transmitter: m.transmitter)) return;
    for (final line in formatter.frameLines(f, monitor: true)) {
      _emit('$line$_eol');
    }
  }
```

- [ ] **Step 4: 通ることを確認する**

Run: `flutter test test/can/periodic_traffic_test.dart test/elm327/monitor_test.dart && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/can/periodic_traffic.dart lib/elm327/elm_session.dart test/can/periodic_traffic_test.dart test/elm327/monitor_test.dart
git commit -m "feat: ATMA/MR/MT の監視表示と周期フレーム

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Simulator の拡張（派生値・積算・レディネス）

**Files:**
- Modify: `lib/vehicle/simulator.dart`（全置き換え）
- Modify: `test/simulator_test.dart` → `test/vehicle/simulator_test.dart` に移して追記

**Interfaces:**
- Consumes: `VehicleState`（Task 3）
- Produces:
  - `class Simulator { Simulator(VehicleState vehicle, {bool Function()? milOn}); bool enabled; void tick(double dtSec); static const readinessStepSec = 60.0; }`
  - `tick` は `enabled` に関係なく積算（始動後時間・走行距離・消去後の距離と時間・MIL 点灯中の距離と時間・ウォームアップ回数・レディネス）を進め、`enabled` のときだけ走行パターンと派生値を動かす。

- [ ] **Step 1: 失敗するテストを書く**

`test/vehicle/simulator_test.dart`（`test/simulator_test.dart` の 3 件をそのまま含め、次を追加）:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/vehicle/simulator.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void ticks(Simulator s, double seconds) {
  for (var i = 0; i < (seconds / 0.2).round(); i++) {
    s.tick(0.2);
  }
}

void main() {
  test('disabled なら走行値は変化しない', () {
    final v = VehicleState.defaults();
    final s = Simulator(v);
    final rpm0 = v.rpm;
    s.tick(1.0);
    expect(v.rpm, rpm0);
  });

  test('enabled で加速フェーズは RPM/速度が上がる', () {
    final v = VehicleState.defaults()
      ..speedKmh = 0
      ..rpm = 800;
    final s = Simulator(v)..enabled = true;
    ticks(s, 6);
    expect(v.speedKmh, greaterThan(0));
    expect(v.rpm, greaterThan(800));
  });

  test('値は妥当な範囲に収まる', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    ticks(s, 400);
    expect(v.speedKmh, inInclusiveRange(0, 200));
    expect(v.rpm, inInclusiveRange(600, 7000));
    expect(v.engineLoadPct, inInclusiveRange(0, 100));
    expect(v.mapKpa, inInclusiveRange(20, 101));
    expect(v.timingDeg, inInclusiveRange(-10, 40));
    expect(v.fuelRateLph, greaterThanOrEqualTo(0));
  });

  test('積算: 36 km/h で 100 秒 → 1 km、経過時間 100 秒（disabled でも進む）', () {
    final v = VehicleState.defaults()..speedKmh = 36;
    final s = Simulator(v);
    final odo0 = v.odometerKm;
    ticks(s, 100);
    expect(v.odometerKm - odo0, closeTo(1.0, 1e-6));
    expect(v.distanceSinceClearKm, closeTo(1.0, 1e-6));
    expect(v.runTimeSec, closeTo(100, 1e-6));
    expect(v.secondsSinceClear, closeTo(100, 1e-6));
    expect(v.distanceWithMilKm, 0);
  });

  test('MIL 点灯中は MIL 距離・時間も進む', () {
    final v = VehicleState.defaults()..speedKmh = 36;
    final s = Simulator(v, milOn: () => true);
    ticks(s, 100);
    expect(v.distanceWithMilKm, closeTo(1.0, 1e-6));
    expect(v.secondsWithMil, closeTo(100, 1e-6));
  });

  test('レディネスは 60 秒ごとに 1 項目ずつ完了', () {
    final v = VehicleState.defaults()..readinessIncomplete = 0x65;
    final s = Simulator(v);
    ticks(s, 59.8);
    expect(v.readinessIncomplete, 0x65);
    ticks(s, 0.2);
    expect(v.readinessIncomplete, 0x64);
    ticks(s, 180);
    expect(v.readinessIncomplete, 0x00);
  });

  test('水温が 60°C 未満から 70°C 以上になるとウォームアップ 1 回', () {
    final v = VehicleState.defaults()..coolantTempC = 30;
    final s = Simulator(v);
    s.tick(0.2);
    v.coolantTempC = 75;
    s.tick(0.2);
    v.coolantTempC = 80;
    s.tick(0.2);
    expect(v.warmupsSinceClear, 1);
  });

  test('派生値: 動的モード中は MAF から燃料消費率を計算', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    s.tick(0.2);
    expect(v.fuelRateLph, closeTo(v.maf / 14.7 / 745 * 3600, 1e-9));
    expect(v.acceleratorPct, closeTo(v.throttlePct * 0.8, 1e-9));
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/vehicle/simulator_test.dart`
Expected: FAIL（`milOn` 引数がない、積算されない）

- [ ] **Step 3: 実装する**

`lib/vehicle/simulator.dart`（全置き換え）:

```dart
import 'vehicle_state.dart';

enum _Phase { idle, accel, cruise, decel }

/// 車両状態を時間で動かす。tick(dt) を外部から駆動する。
/// 積算（距離・時間・レディネス）は常に、走行パターンと派生値は enabled のときだけ進める。
class Simulator {
  Simulator(this.vehicle, {bool Function()? milOn}) : _milOn = milOn ?? (() => false);

  final VehicleState vehicle;
  final bool Function() _milOn;
  bool enabled = false;

  static const readinessStepSec = 60.0;

  _Phase _phase = _Phase.idle;
  double _phaseT = 0;
  double _readinessT = 0;
  bool _coldSeen = false;

  static const _phaseDur = {
    _Phase.idle: 3.0,
    _Phase.accel: 8.0,
    _Phase.cruise: 10.0,
    _Phase.decel: 6.0,
  };

  void tick(double dtSec) {
    _accumulate(dtSec);
    if (!enabled) return;
    _phaseT += dtSec;
    if (_phaseT >= _phaseDur[_phase]!) {
      _phaseT = 0;
      _phase = _next(_phase);
    }
    switch (_phase) {
      case _Phase.idle:
        _approach(targetSpeed: 0, targetRpm: 800, dt: dtSec);
      case _Phase.accel:
        _approach(targetSpeed: 100, targetRpm: 3500, dt: dtSec);
      case _Phase.cruise:
        _approach(targetSpeed: 90, targetRpm: 2200, dt: dtSec);
      case _Phase.decel:
        _approach(targetSpeed: 0, targetRpm: 900, dt: dtSec);
    }
    _deriveSecondary();
  }

  void _accumulate(double dt) {
    final v = vehicle;
    final km = v.speedKmh * dt / 3600;
    v
      ..runTimeSec += dt
      ..odometerKm += km
      ..distanceSinceClearKm += km
      ..secondsSinceClear += dt;
    if (_milOn()) {
      v
        ..distanceWithMilKm += km
        ..secondsWithMil += dt;
    }
    if (v.coolantTempC < 60) {
      _coldSeen = true;
    } else if (_coldSeen && v.coolantTempC >= 70) {
      v.warmupsSinceClear++;
      _coldSeen = false;
    }
    if (v.readinessIncomplete == 0) {
      _readinessT = 0;
      return;
    }
    _readinessT += dt;
    if (_readinessT >= readinessStepSec - 1e-9) {
      _readinessT = 0;
      v.readinessIncomplete &= v.readinessIncomplete - 1; // 最下位の未完了ビットを完了にする
    }
  }

  _Phase _next(_Phase p) => switch (p) {
        _Phase.idle => _Phase.accel,
        _Phase.accel => _Phase.cruise,
        _Phase.cruise => _Phase.decel,
        _Phase.decel => _Phase.idle,
      };

  void _approach({required double targetSpeed, required int targetRpm, required double dt}) {
    final k = (dt * 0.6).clamp(0.0, 1.0);
    vehicle.speedKmh += (targetSpeed - vehicle.speedKmh) * k;
    vehicle.rpm += ((targetRpm - vehicle.rpm) * k).round();
    vehicle.speedKmh = vehicle.speedKmh.clamp(0, 200);
    vehicle.rpm = vehicle.rpm.clamp(600, 7000);
  }

  void _deriveSecondary() {
    final v = vehicle;
    v.throttlePct = ((v.rpm - 800) / 6200 * 100).clamp(0, 100);
    v.engineLoadPct = (v.throttlePct * 0.8 + 15).clamp(0, 100);
    v.maf = (v.rpm / 800 * 3.5).clamp(0, 200);
    v.coolantTempC = (v.coolantTempC + (90 - v.coolantTempC) * 0.01).clamp(20, 110);
    v.mapKpa = (25 + v.throttlePct * 0.7).clamp(20, 101);
    v.timingDeg = (10 + (v.rpm - 800) / 6200 * 25).clamp(-10, 40);
    v.fuelRateLph = v.maf / 14.7 / 745 * 3600; // 空燃比 14.7、ガソリン 745 g/L
    v.catalystTempC += (400 + v.engineLoadPct * 3 - v.catalystTempC) * 0.02;
    v.oilTempC += (v.coolantTempC + 5 - v.oilTempC) * 0.01;
    v.acceleratorPct = v.throttlePct * 0.8;
    v.absLoadPct = v.engineLoadPct * 0.9;
  }
}
```

- [ ] **Step 4: 通ることを確認する**

Run: `git rm test/simulator_test.dart && flutter test test/vehicle/simulator_test.dart && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/vehicle/simulator.dart test/vehicle/simulator_test.dart
git commit -m "feat: Simulator に派生値・積算・レディネス完了を追加

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: 中核の組み立て・コントローラ・TCP・CLI・旧エンジンの削除

**Files:**
- Create: `lib/app/emulation_core.dart`, `lib/app/control_commands.dart`, `lib/transport/tcp_transport.dart`, `bin/elm327_tcp.dart`
- Modify: `lib/transport/transport.dart`（`tcp` 追加）、`lib/transport/transport_bridge.dart`（`disconnect` 追加）、`lib/app/emulator_controller.dart`（全置き換え）、`lib/vehicle/vehicle_state.dart`（`dtcs` と `vin` を削除）、`lib/ui/dtc_editor.dart`、`lib/ui/home_page.dart`（ログ表示の型だけ）、`test/vehicle/vehicle_state_test.dart`
- Delete: `lib/elm327/elm327_engine.dart`, `lib/elm327/at_command_handler.dart`, `lib/elm327/obd_command_handler.dart`, `lib/elm327/obd_encoding.dart`, `test/elm327_engine_test.dart`, `test/at_command_handler_test.dart`, `test/obd_command_handler_test.dart`, `test/obd_encoding_test.dart`
- Test: `test/app/emulation_core_test.dart`, `test/app/control_commands_test.dart`, `test/transport/tcp_transport_test.dart`, `test/app/emulator_controller_test.dart`, `test/support/fake_bridge.dart`

**Interfaces:**
- Consumes: Task 1〜12 のすべて
- Produces:
  - `class EmulationCore { EmulationCore({Random? random}); VehicleState vehicle; EcuProfile engine, transmission; List<EcuProfile> ecus; VirtualCanBus bus; FaultConfig faultConfig; FaultInjector faults; ObdServices obd; UdsServices uds; Simulator simulator; PeriodicTraffic traffic; EcuProfile ecuByName(String); void start(); ElmSession newSession(); void dispose(); }` — 生成時にエンジンへ確定 DTC `P0301` を入れる（フリーズフレームも保存）。
  - `Future<String> applyControl(EmulationCore core, String line, {Future<void> Function()? disconnect})` — 戻り値は `ok` か `error <理由>`
  - `enum TransportType { ble, spp, tcp }`（`wire` は `ble` / `spp` / `tcp`）
  - `TransportBridge.disconnect(TransportType t)`
  - `class TcpTransport { TcpTransport({int port = 35000}); Future<void> start(); Future<void> stop(); Future<void> disconnect(); void send(List<int> bytes); Stream<List<int>> get onReceive; Stream<String> get onConnection; int get port; bool get isListening; bool get hasClient; }`（`onConnection` は `connected <アドレス>:<ポート>` / `disconnected`）
  - `enum LogKind { input, output, can, fault, info }`、`class LogEntry { final DateTime time; final LogKind kind; final String text; }`
  - `enum DtcKind { confirmed, pending, permanent }`
  - `class EmulatorController extends ChangeNotifier`:
    - 生成: `EmulatorController({TransportBridge? bridge, EmulationCore? core, bool? tcpAvailable})`
    - フィールド・getter: `core`, `bridge`, `tcp`, `caps`, `connState`（`Map<TransportType, String>`）, `log`（`List<LogEntry>`、最大 2000）, `useFff0`, `sessions`, `vehicle`, `simulator`, `displayState`, `headlineStatus`, `connectedTransports`
    - 操作: `init()`, `dispose()`, `startBle()`, `stopBle()`, `startSpp()`, `stopSpp()`, `startTcp()`, `stopTcp()`, `disconnect(TransportType)`, `disconnectAll()`, `setBleProfile(bool)`, `setSimEnabled(bool)`, `notify()`, `statusText(TransportType)`, `updateFaults(void Function(FaultConfig))`, `activeFaultDescriptions()`, `addDtc(EcuProfile, DtcKind, String) → bool`, `removeDtc(EcuProfile, DtcKind, String)`, `clearDtcs(EcuProfile)`, `setEcuEnabled(EcuProfile, bool)`, `updateEcuInfo(EcuProfile, {required String vin, required String calid, required String cvnHex, required String name}) → String?`, `setDid(EcuProfile, int did, DidValue value)`, `removeDid(EcuProfile, int did)`, `clearLog()`
  - `bin/elm327_tcp.dart`: `dart run bin/elm327_tcp.dart [--port 35000] [--transmission] [--dynamic] [--quiet]`。起動すると `listening <port>` を出し、標準入力の 1 行を `applyControl` に渡して結果を 1 行出す。接続ごとに新しい `ElmSession`。

- [ ] **Step 1: 失敗するテストを書く**

`test/support/fake_bridge.dart`:

```dart
import 'dart:async';

import 'package:elm327emu/transport/transport.dart';
import 'package:elm327emu/transport/transport_bridge.dart';

/// Platform Channel を使わない TransportBridge。
class FakeTransportBridge extends TransportBridge {
  final rx = StreamController<({TransportType transport, List<int> bytes})>.broadcast(sync: true);
  final conn = StreamController<({TransportType transport, String state, String device})>.broadcast(sync: true);
  final sent = <(TransportType, List<int>)>[];
  final calls = <String>[];

  String sentText(TransportType t) => sent.where((e) => e.$1 == t).map((e) => String.fromCharCodes(e.$2)).join();

  @override
  Future<List<TransportType>> capabilities() async => [TransportType.ble, TransportType.spp];
  @override
  Stream<({TransportType transport, List<int> bytes})> get onReceive => rx.stream;
  @override
  Stream<({TransportType transport, String state, String device})> get onConnection => conn.stream;
  @override
  Future<void> send(TransportType t, List<int> bytes) async => sent.add((t, bytes));
  @override
  Future<void> startBle({bool useFff0 = false}) async => calls.add('startBle:$useFff0');
  @override
  Future<void> stopBle() async => calls.add('stopBle');
  @override
  Future<void> startSpp() async => calls.add('startSpp');
  @override
  Future<void> stopSpp() async => calls.add('stopSpp');
  @override
  Future<void> disconnect(TransportType t) async => calls.add('disconnect:${t.wire}');
}
```

`test/app/emulation_core_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/app/emulation_core.dart';

void main() {
  test('生成時にエンジンへ P0301 とフリーズフレーム', () {
    final core = EmulationCore();
    expect(core.engine.confirmedDtcs, ['P0301']);
    expect(core.engine.freezeFrame?.dtc, 'P0301');
    expect(core.ecus.map((e) => e.name), ['engine', 'transmission']);
    expect(core.ecuByName('transmission'), same(core.transmission));
  });

  test('start 後のセッションは ECU と周期フレームにつながる', () {
    fakeAsync((async) {
      final core = EmulationCore()..start();
      final s = core.newSession();
      final out = StringBuffer();
      s.output.listen((b) => out.write(String.fromCharCodes(b)));
      s.input('ATE0\r0100\r'.codeUnits);
      async.elapse(const Duration(milliseconds: 100));
      expect(out.toString(), 'ATE0\rOK\r\r>SEARCHING...\r41 00 BE 3F A0 13 \r\r>');
      final ids = <int>{};
      core.bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(milliseconds: 1000));
      expect(ids, containsAll([0x0C9, 0x3E9, 0x4C1]));
      core.dispose();
    });
  });
}
```

`test/app/control_commands_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:elm327emu/app/control_commands.dart';
import 'package:elm327emu/app/emulation_core.dart';
import 'package:elm327emu/can/fault_injector.dart';

void main() {
  late EmulationCore core;
  setUp(() => core = EmulationCore());

  test('障害の切り替え', () async {
    expect(await applyControl(core, 'ignition off'), 'ok');
    expect(core.faultConfig.ignitionOff, isTrue);
    expect(await applyControl(core, 'ignition on'), 'ok');
    expect(core.faultConfig.ignitionOff, isFalse);
    expect(await applyControl(core, 'silent engine on'), 'ok');
    expect(core.faultConfig.silentEcus, {'engine'});
    expect(await applyControl(core, 'silent engine off'), 'ok');
    expect(core.faultConfig.silentEcus, isEmpty);
    expect(await applyControl(core, 'delay 350'), 'ok');
    expect(core.faultConfig.delayMs, 350);
    expect(await applyControl(core, 'drop 100'), 'ok');
    expect(core.faultConfig.dropPercent, 100);
    expect(await applyControl(core, 'pending on'), 'ok');
    expect(core.faultConfig.responsePending, isTrue);
    expect(await applyControl(core, 'truncate on'), 'ok');
    expect(core.faultConfig.truncateMultiFrame, isTrue);
  });

  test('エラー応答', () async {
    expect(await applyControl(core, 'error canError once'), 'ok');
    expect(core.faultConfig.error, ElmErrorKind.canError);
    expect(core.faultConfig.errorTrigger, ErrorTrigger.once);
    expect(core.faultConfig.errorArmed, isTrue);
    expect(await applyControl(core, 'error bufferFull always'), 'ok');
    expect(core.faultConfig.errorTrigger, ErrorTrigger.always);
    expect(await applyControl(core, 'error off'), 'ok');
    expect(core.faultConfig.errorArmed, isFalse);
    expect(await applyControl(core, 'error nope once'), startsWith('error'));
  });

  test('車両・DTC・ECU・切断', () async {
    expect(await applyControl(core, 'rpm 2150'), 'ok');
    expect(core.vehicle.rpm, 2150);
    expect(await applyControl(core, 'speed 62'), 'ok');
    expect(core.vehicle.speedKmh, 62);
    expect(await applyControl(core, 'dtc add P0420'), 'ok');
    expect(core.engine.confirmedDtcs, ['P0301', 'P0420']);
    expect(await applyControl(core, 'dtc add X1'), startsWith('error'));
    expect(await applyControl(core, 'dtc clear'), 'ok');
    expect(core.engine.confirmedDtcs, isEmpty);
    expect(await applyControl(core, 'transmission on'), 'ok');
    expect(core.transmission.enabled, isTrue);
    var disconnected = false;
    expect(await applyControl(core, 'disconnect', disconnect: () async => disconnected = true), 'ok');
    expect(disconnected, isTrue);
  });

  test('不明・値の形式違い', () async {
    expect(await applyControl(core, 'hello'), startsWith('error'));
    expect(await applyControl(core, 'delay abc'), startsWith('error'));
    expect(await applyControl(core, 'silent brake on'), startsWith('error'));
  });
}
```

`test/transport/tcp_transport_test.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:elm327emu/transport/tcp_transport.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('1 接続を受けて送受信し、2 本目は切り、disconnect で切れる', () async {
    final t = TcpTransport(port: 0);
    await t.start();
    expect(t.isListening, isTrue);
    final conns = <String>[];
    t.onConnection.listen(conns.add);
    final got = <int>[];
    t.onReceive.listen(got.addAll);

    final c1 = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    final c1Data = <int>[];
    final c1Done = Completer<void>();
    c1.listen(c1Data.addAll, onDone: c1Done.complete);
    await _settle();
    expect(conns.single, startsWith('connected 127.0.0.1:'));
    expect(t.hasClient, isTrue);

    c1.add('ATI\r'.codeUnits);
    await c1.flush();
    await _settle();
    expect(String.fromCharCodes(got), 'ATI\r');

    t.send('ELM327 v1.5\r\r>'.codeUnits);
    await _settle();
    expect(String.fromCharCodes(c1Data), 'ELM327 v1.5\r\r>');

    final c2 = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    final c2Done = Completer<void>();
    c2.listen((_) {}, onDone: c2Done.complete, onError: (Object _) => c2Done.complete());
    await c2Done.future.timeout(const Duration(seconds: 2));

    await t.disconnect();
    await c1Done.future.timeout(const Duration(seconds: 2));
    await _settle();
    expect(conns.last, 'disconnected');
    expect(t.hasClient, isFalse);

    await t.stop();
    expect(t.isListening, isFalse);
    c1.destroy();
    c2.destroy();
  });

  test('クライアント側から切っても disconnected', () async {
    final t = TcpTransport(port: 0);
    await t.start();
    final conns = <String>[];
    t.onConnection.listen(conns.add);
    final c = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    await _settle();
    await c.close();
    await _settle();
    expect(conns, [startsWith('connected'), 'disconnected']);
    await t.stop();
  });
}
```

`test/app/emulator_controller_test.dart`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';
import 'package:elm327emu/transport/transport.dart';
import '../support/fake_bridge.dart';

void main() {
  (EmulatorController, FakeTransportBridge) make(FakeAsync async) {
    final bridge = FakeTransportBridge();
    final c = EmulatorController(bridge: bridge, tcpAvailable: false);
    c.init();
    async.flushMicrotasks();
    return (c, bridge);
  }

  void rx(FakeTransportBridge b, TransportType t, String s) =>
      b.rx.add((transport: t, bytes: s.codeUnits));

  test('受信を接続ごとのセッションに渡し、応答を送り返す', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      expect(c.caps, [TransportType.ble, TransportType.spp]);
      rx(b, TransportType.ble, 'ATE0\r');
      rx(b, TransportType.spp, 'ATI\r');
      async.elapse(const Duration(milliseconds: 1));
      expect(b.sentText(TransportType.ble), 'ATE0\rOK\r\r>');
      expect(b.sentText(TransportType.spp), 'ATI\rELM327 v1.5\r\r>');
      expect(c.sessions.keys, containsAll([TransportType.ble, TransportType.spp]));
      expect(c.displayState.echo, isTrue); // 最後に受信したのは SPP（エコーあり）
      c.dispose();
    });
  });

  test('ログに送受信と CAN フレームが残る（周期フレームは残さない）', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      rx(b, TransportType.ble, 'ATE0\r0100\r');
      async.elapse(const Duration(milliseconds: 500));
      final kinds = c.log.map((e) => e.kind).toSet();
      expect(kinds, containsAll([LogKind.input, LogKind.output, LogKind.can]));
      expect(c.log.where((e) => e.kind == LogKind.can).any((e) => e.text.contains('0C9')), isFalse);
      expect(c.log.firstWhere((e) => e.kind == LogKind.input).text, r'ATE0\r0100\r');
      c.dispose();
    });
  });

  test('切断イベントでセッションを破棄する（Review Focus 4）', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      rx(b, TransportType.ble, 'ATE0\r');
      async.elapse(const Duration(milliseconds: 1));
      b.conn.add((transport: TransportType.ble, state: 'connected', device: 'AA'));
      expect(c.connState[TransportType.ble], '接続中 · AA');
      expect(c.headlineStatus, 'BLE 接続中');
      b.conn.add((transport: TransportType.ble, state: 'disconnected', device: 'AA'));
      expect(c.sessions.containsKey(TransportType.ble), isFalse);
      expect(c.connState[TransportType.ble], '待ち受け中');
      async.elapse(const Duration(seconds: 1));
      c.dispose();
    });
  });

  test('障害・DTC・ECU の操作', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.updateFaults((f) => f.delayMs = 350);
      expect(c.activeFaultDescriptions(), ['応答の遅延 350ms']);
      expect(c.log.last.kind, LogKind.fault);
      expect(c.addDtc(c.core.engine, DtcKind.confirmed, ' p0420 '), isTrue);
      expect(c.core.engine.confirmedDtcs, ['P0301', 'P0420']);
      expect(c.addDtc(c.core.engine, DtcKind.pending, 'X1'), isFalse);
      c.addDtc(c.core.engine, DtcKind.permanent, 'P0301');
      c.clearDtcs(c.core.engine);
      expect(c.core.engine.confirmedDtcs, isEmpty);
      expect(c.core.engine.permanentDtcs, ['P0301']);
      c.setEcuEnabled(c.core.transmission, true);
      expect(c.core.transmission.enabled, isTrue);
      expect(c.updateEcuInfo(c.core.engine, vin: 'SHORT', calid: 'X', cvnHex: '1A2B3C4D', name: 'ECM'), isNotNull);
      expect(c.updateEcuInfo(c.core.engine, vin: 'JT2BF22K1W0123456', calid: 'CAL1', cvnHex: '01020304', name: 'ECM-Test'), isNull);
      expect(c.core.engine.vin, 'JT2BF22K1W0123456');
      expect(c.core.engine.cvn, [1, 2, 3, 4]);
      c.setDid(c.core.engine, 0x1234, DidValue.ascii('AB'));
      expect(c.core.engine.dids[0x1234]!.display, 'AB');
      c.removeDid(c.core.engine, 0x1234);
      expect(c.core.engine.dids.containsKey(0x1234), isFalse);
      c.updateFaults((f) {
        f.error = ElmErrorKind.canError;
        f.errorArmed = true;
      });
      expect(c.activeFaultDescriptions().last, 'エラー応答 CAN ERROR（次の1回）');
      c.dispose();
    });
  });

  test('BLE の開始・切断はブリッジへ渡す', () {
    fakeAsync((async) {
      final (c, b) = make(async);
      c.setBleProfile(true);
      c.startBle();
      c.disconnect(TransportType.ble);
      async.flushMicrotasks();
      expect(b.calls, ['startBle:true', 'disconnect:ble']);
      expect(c.statusText(TransportType.ble), '待ち受け中');
      c.dispose();
    });
  });
}
```

`test/vehicle/vehicle_state_test.dart` から `expect(v.vin.length, 17);` と `expect(v.dtcs, ['P0301']);` を削除する。

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/app test/transport`
Expected: FAIL（`emulation_core.dart` などがない）

- [ ] **Step 3: 実装する（中核・制御コマンド・TCP）**

`lib/app/emulation_core.dart`:

```dart
import 'dart:math';

import '../can/fault_injector.dart';
import '../can/periodic_traffic.dart';
import '../can/virtual_can_bus.dart';
import '../ecu/ecu.dart';
import '../ecu/ecu_profile.dart';
import '../ecu/obd_services.dart';
import '../ecu/uds_services.dart';
import '../elm327/elm_session.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';

/// 車両・ECU・バス・障害設定の組み立て。Flutter アプリと CLI の両方が使う。
class EmulationCore {
  EmulationCore({Random? random}) {
    faults = FaultInjector(faultConfig, random: random);
    obd = ObdServices(vehicle);
    obd.addConfirmedDtc(engine, 'P0301');
    simulator = Simulator(vehicle, milOn: () => engine.confirmedDtcs.isNotEmpty);
    traffic = PeriodicTraffic(bus, vehicle, faults);
  }

  final VehicleState vehicle = VehicleState.defaults();
  final EcuProfile engine = EcuProfile.engine();
  final EcuProfile transmission = EcuProfile.transmission();
  late final List<EcuProfile> ecus = [engine, transmission];
  final VirtualCanBus bus = VirtualCanBus();
  final FaultConfig faultConfig = FaultConfig();
  late final FaultInjector faults;
  late final ObdServices obd;
  final UdsServices uds = UdsServices();
  late final Simulator simulator;
  late final PeriodicTraffic traffic;

  final List<Ecu> _nodes = [];

  EcuProfile ecuByName(String name) => ecus.firstWhere((e) => e.name == name);

  void start() {
    if (_nodes.isNotEmpty) return;
    for (final p in ecus) {
      final node = Ecu(profile: p, bus: bus, obd: obd, uds: uds, faults: faults);
      bus.attach(node);
      _nodes.add(node);
    }
    traffic.start();
  }

  ElmSession newSession() =>
      ElmSession(bus: bus, faults: faults, voltage: () => vehicle.batteryVoltage);

  void dispose() {
    traffic.stop();
    for (final n in _nodes) {
      n.dispose();
    }
    _nodes.clear();
  }
}
```

`lib/app/control_commands.dart`:

```dart
import '../can/fault_injector.dart';
import '../ecu/dtc.dart';
import 'emulation_core.dart';

/// CLI（bin/elm327_tcp.dart）が標準入力から受ける制御コマンド。戻り値は 'ok' か 'error <理由>'。
///
/// ignition on|off / silent <engine|transmission> on|off / delay <ms> / drop <pct>
/// pending on|off / truncate on|off / error <種類> once|always / error off
/// transmission on|off / rpm <n> / speed <n> / dtc add <code> / dtc clear / disconnect
Future<String> applyControl(EmulationCore core, String line,
    {Future<void> Function()? disconnect}) async {
  final f = core.faultConfig;
  final parts = line.trim().split(RegExp(r'\s+'));
  bool? onOff(String s) => s == 'on' ? true : (s == 'off' ? false : null);
  String err(String why) => 'error $why';

  switch (parts) {
    case ['ignition', final v] when onOff(v) != null:
      f.ignitionOff = !onOff(v)!;
    case ['silent', final ecu, final v] when onOff(v) != null:
      if (!core.ecus.any((e) => e.name == ecu)) return err('unknown ecu: $ecu');
      onOff(v)! ? f.silentEcus.add(ecu) : f.silentEcus.remove(ecu);
    case ['delay', final ms]:
      final n = int.tryParse(ms);
      if (n == null || n < 0) return err('delay must be >= 0');
      f.delayMs = n;
    case ['drop', final pct]:
      final n = int.tryParse(pct);
      if (n == null || n < 0 || n > 100) return err('drop must be 0..100');
      f.dropPercent = n;
    case ['pending', final v] when onOff(v) != null:
      f.responsePending = onOff(v)!;
    case ['truncate', final v] when onOff(v) != null:
      f.truncateMultiFrame = onOff(v)!;
    case ['error', 'off']:
      f.errorArmed = false;
    case ['error', final kind, final trigger] when trigger == 'once' || trigger == 'always':
      final k = ElmErrorKind.values.where((e) => e.name == kind).firstOrNull;
      if (k == null) return err('unknown error kind: $kind');
      f
        ..error = k
        ..errorTrigger = trigger == 'once' ? ErrorTrigger.once : ErrorTrigger.always
        ..errorArmed = true;
    case ['transmission', final v] when onOff(v) != null:
      core.transmission.enabled = onOff(v)!;
    case ['rpm', final n] when int.tryParse(n) != null:
      core.vehicle.rpm = int.parse(n);
    case ['speed', final n] when double.tryParse(n) != null:
      core.vehicle.speedKmh = double.parse(n);
    case ['dtc', 'add', final code]:
      if (!isValidDtc(code)) return err('invalid dtc: $code');
      core.obd.addConfirmedDtc(core.engine, code);
    case ['dtc', 'clear']:
      core.obd.clearDtcs(core.engine);
    case ['disconnect']:
      await disconnect?.call();
    default:
      return err('unknown command: ${line.trim()}');
  }
  return 'ok';
}
```

`lib/transport/tcp_transport.dart`:

```dart
import 'dart:async';
import 'dart:io';

/// 開発用の TCP サーバ（127.0.0.1、同時 1 接続。2 本目は即切断）。python-OBD などの検証に使う。
class TcpTransport {
  TcpTransport({int port = 35000}) : _requestedPort = port;

  final int _requestedPort;
  ServerSocket? _server;
  Socket? _client;
  final _rx = StreamController<List<int>>.broadcast();
  final _conn = StreamController<String>.broadcast();

  Stream<List<int>> get onReceive => _rx.stream;

  /// 'connected <アドレス>:<ポート>' / 'disconnected'
  Stream<String> get onConnection => _conn.stream;

  bool get isListening => _server != null;
  bool get hasClient => _client != null;
  int get port => _server?.port ?? _requestedPort;

  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _requestedPort);
    _server = server;
    server.listen(_accept);
  }

  void _accept(Socket s) {
    if (_client != null) {
      s.destroy();
      return;
    }
    _client = s;
    s.setOption(SocketOption.tcpNoDelay, true);
    _conn.add('connected ${s.remoteAddress.address}:${s.remotePort}');
    s.listen(
      _rx.add,
      onDone: () => _drop(s),
      onError: (Object _) => _drop(s),
      cancelOnError: true,
    );
  }

  void _drop(Socket s) {
    if (!identical(_client, s)) return;
    _client = null;
    s.destroy();
    _conn.add('disconnected');
  }

  void send(List<int> bytes) {
    final c = _client;
    if (c == null) return;
    try {
      c.add(bytes);
    } on Object {
      _drop(c); // 切断直後の書き込み
    }
  }

  Future<void> disconnect() async {
    final c = _client;
    if (c != null) _drop(c);
  }

  Future<void> stop() async {
    await disconnect();
    await _server?.close();
    _server = null;
  }
}
```

`lib/transport/transport.dart`（全置き換え）:

```dart
enum TransportType { ble, spp, tcp }

extension TransportTypeName on TransportType {
  String get wire => name; // 'ble' / 'spp' / 'tcp'
  String get label => switch (this) {
        TransportType.ble => 'BLE',
        TransportType.spp => 'SPP',
        TransportType.tcp => 'TCP',
      };
  static TransportType fromWire(String s) => switch (s) {
        'spp' => TransportType.spp,
        'tcp' => TransportType.tcp,
        _ => TransportType.ble,
      };
}
```

`lib/transport/transport_bridge.dart` の `stopSpp` の下に追加:

```dart
  /// 接続中の相手だけ切る（待ち受けは続ける）。macOS の BLE は疑似切断。
  Future<void> disconnect(TransportType t) =>
      _control.invokeMethod('disconnect', {'transport': t.wire});
```

- [ ] **Step 4: 実装する（コントローラ）**

`lib/app/emulator_controller.dart`（全置き換え）:

```dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../can/fault_injector.dart';
import '../can/periodic_traffic.dart';
import '../can/virtual_can_bus.dart';
import '../ecu/dtc.dart';
import '../ecu/ecu.dart';
import '../ecu/ecu_profile.dart';
import '../elm327/elm_session.dart';
import '../elm327/elm_state.dart';
import '../transport/tcp_transport.dart';
import '../transport/transport.dart';
import '../transport/transport_bridge.dart';
import '../util/hex.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';
import 'emulation_core.dart';

enum LogKind { input, output, can, fault, info }

class LogEntry {
  LogEntry(this.time, this.kind, this.text);
  final DateTime time;
  final LogKind kind;
  final String text;
}

enum DtcKind { confirmed, pending, permanent }

/// Flutter 側の結線。接続ごとに ElmSession を持ち、UI からの操作を中核へ渡す。
class EmulatorController extends ChangeNotifier {
  EmulatorController({TransportBridge? bridge, EmulationCore? core, bool? tcpAvailable})
      : bridge = bridge ?? TransportBridge(),
        core = core ?? EmulationCore(),
        _tcpAvailable = tcpAvailable ?? (!kIsWeb && Platform.isMacOS);

  final EmulationCore core;
  final TransportBridge bridge;
  final TcpTransport tcp = TcpTransport();
  final bool _tcpAvailable;

  static const maxLog = 2000;

  List<TransportType> caps = [];
  final Map<TransportType, String> connState = {};
  final Map<TransportType, ElmSession> sessions = {};
  final List<LogEntry> log = [];
  bool useFff0 = false;
  TransportType? _lastActive;
  final ElmState _idleState = ElmState();
  Timer? _tick;
  void Function()? _unlistenBus;
  final List<StreamSubscription<Object?>> _subs = [];

  VehicleState get vehicle => core.vehicle;
  Simulator get simulator => core.simulator;

  /// 接続タブに出す ELM の状態（最後に受信した接続のもの）。
  ElmState get displayState => sessions[_lastActive]?.state ?? _idleState;

  List<TransportType> get connectedTransports => [
        for (final e in connState.entries)
          if (e.value.startsWith('接続中')) e.key,
      ];

  String get headlineStatus {
    final c = connectedTransports;
    return c.isEmpty ? '未接続' : '${c.first.label} 接続中';
  }

  String statusText(TransportType t) => connState[t] ?? '停止中';

  Future<void> init() async {
    core.start();
    caps = [...await bridge.capabilities(), if (_tcpAvailable) TransportType.tcp];
    _subs
      ..add(bridge.onReceive.listen((e) => _receive(e.transport, e.bytes)))
      ..add(bridge.onConnection.listen((e) => _onConnection(e.transport, e.state, e.device)))
      ..add(tcp.onReceive.listen((b) => _receive(TransportType.tcp, b)))
      ..add(tcp.onConnection.listen((s) {
        final parts = s.split(' ');
        _onConnection(TransportType.tcp, parts.first, parts.length > 1 ? parts[1] : '');
      }));
    _unlistenBus = core.bus.listen(_onBus);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      core.simulator.tick(0.2);
      notifyListeners();
    });
    notifyListeners();
  }

  ElmSession _sessionFor(TransportType t) => sessions.putIfAbsent(t, () {
        final s = core.newSession();
        s.output.listen((bytes) {
          _log(LogKind.output, _escape(bytes));
          if (t == TransportType.tcp) {
            tcp.send(bytes);
          } else {
            bridge.send(t, bytes);
          }
        });
        return s;
      });

  void _receive(TransportType t, List<int> bytes) {
    _lastActive = t;
    _log(LogKind.input, _escape(bytes));
    _sessionFor(t).input(bytes);
  }

  void _onConnection(TransportType t, String state, String device) {
    if (state == 'connected') {
      connState[t] = device.isEmpty ? '接続中' : '接続中 · $device';
    } else {
      connState[t] = '待ち受け中';
      sessions.remove(t)?.dispose();
    }
    _log(LogKind.info, '[${t.label}] $state $device'.trim());
  }

  bool _isDiagnostic(int id, bool extended) =>
      extended || (id >= 0x7DF && id <= 0x7EF) || !PeriodicTraffic.ids.contains(id);

  void _onBus(BusEvent e) {
    final f = e.frame;
    if (!_isDiagnostic(f.id, f.extended)) return;
    _log(LogKind.can, '${e.sender is Ecu ? 'RX' : 'TX'} $f');
  }

  static String _escape(List<int> bytes) =>
      String.fromCharCodes(bytes).replaceAll('\r', r'\r').replaceAll('\n', r'\n');

  void _log(LogKind kind, String text) {
    log.add(LogEntry(DateTime.now(), kind, text));
    if (log.length > maxLog) log.removeRange(0, log.length - maxLog);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  // ---- 接続 ----
  Future<void> startBle() async {
    await bridge.startBle(useFff0: useFff0);
    connState[TransportType.ble] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopBle() async {
    await bridge.stopBle();
    connState.remove(TransportType.ble);
    sessions.remove(TransportType.ble)?.dispose();
    notifyListeners();
  }

  Future<void> startSpp() async {
    await bridge.startSpp();
    connState[TransportType.spp] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopSpp() async {
    await bridge.stopSpp();
    connState.remove(TransportType.spp);
    sessions.remove(TransportType.spp)?.dispose();
    notifyListeners();
  }

  Future<void> startTcp() async {
    await tcp.start();
    connState[TransportType.tcp] = '待ち受け中';
    notifyListeners();
  }

  Future<void> stopTcp() async {
    await tcp.stop();
    connState.remove(TransportType.tcp);
    sessions.remove(TransportType.tcp)?.dispose();
    notifyListeners();
  }

  Future<void> disconnect(TransportType t) async {
    _log(LogKind.fault, '${t.label} を切断');
    if (t == TransportType.tcp) {
      await tcp.disconnect();
    } else {
      await bridge.disconnect(t);
    }
  }

  Future<void> disconnectAll() async {
    for (final t in connectedTransports) {
      await disconnect(t);
    }
  }

  void setBleProfile(bool fff0) {
    useFff0 = fff0;
    notifyListeners();
  }

  void setSimEnabled(bool on) {
    core.simulator.enabled = on;
    notifyListeners();
  }

  void notify() => notifyListeners();

  // ---- 障害 ----
  void updateFaults(void Function(FaultConfig f) change) {
    change(core.faultConfig);
    final active = activeFaultDescriptions();
    _log(LogKind.fault, active.isEmpty ? '障害: なし' : '障害: ${active.join(' / ')}');
  }

  List<String> activeFaultDescriptions() {
    final f = core.faultConfig;
    final error = f.error;
    return [
      if (f.ignitionOff) 'イグニッション OFF',
      for (final p in core.ecus)
        if (f.silentEcus.contains(p.name)) '${p.label} の無応答',
      if (f.delayMs > 0) '応答の遅延 ${f.delayMs}ms',
      if (f.dropPercent > 0) 'ランダムな欠落 ${f.dropPercent}%',
      if (f.responsePending) '応答保留（7F xx 78）',
      if (f.truncateMultiFrame) '複数フレームの途中欠落',
      if (f.errorArmed && error != null)
        'エラー応答 ${error.text}（${f.errorTrigger == ErrorTrigger.once ? '次の1回' : '常に'}）',
    ];
  }

  // ---- DTC ----
  List<String> _list(EcuProfile e, DtcKind kind) => switch (kind) {
        DtcKind.confirmed => e.confirmedDtcs,
        DtcKind.pending => e.pendingDtcs,
        DtcKind.permanent => e.permanentDtcs,
      };

  /// 前後の空白を除き大文字にして追加する。形式違いは false。
  bool addDtc(EcuProfile e, DtcKind kind, String code) {
    final c = code.trim().toUpperCase();
    if (!isValidDtc(c)) return false;
    if (kind == DtcKind.confirmed) {
      core.obd.addConfirmedDtc(e, c);
    } else if (!_list(e, kind).contains(c)) {
      _list(e, kind).add(c);
    }
    notifyListeners();
    return true;
  }

  void removeDtc(EcuProfile e, DtcKind kind, String code) {
    _list(e, kind).remove(code);
    notifyListeners();
  }

  void clearDtcs(EcuProfile e) {
    core.obd.clearDtcs(e);
    notifyListeners();
  }

  // ---- ECU ----
  void setEcuEnabled(EcuProfile e, bool enabled) {
    e.enabled = enabled;
    notifyListeners();
  }

  static final _printable = RegExp(r'^[\x20-\x7E]*$');

  /// Mode 09 の情報を更新する。問題があればエラー文を返す（何も変えない）。
  String? updateEcuInfo(EcuProfile e,
      {required String vin, required String calid, required String cvnHex, required String name}) {
    if (vin.isNotEmpty && (vin.length != 17 || !_printable.hasMatch(vin))) {
      return 'VIN は 17 文字（空にすると Mode 09 02 に応答しない）';
    }
    if (calid.isEmpty || calid.length > 16 || !_printable.hasMatch(calid)) {
      return 'CALID は 1〜16 文字';
    }
    final cvn = cvnHex.length == 8 ? parseHexBytes(cvnHex) : null;
    if (cvn == null) return 'CVN は 16 進 8 桁';
    if (name.isEmpty || name.length > 20 || !_printable.hasMatch(name)) {
      return 'ECU 名は 1〜20 文字';
    }
    e
      ..vin = vin
      ..calid = calid
      ..cvn = cvn
      ..ecuName = name;
    notifyListeners();
    return null;
  }

  void setDid(EcuProfile e, int did, DidValue value) {
    e.dids[did] = value;
    notifyListeners();
  }

  void removeDid(EcuProfile e, int did) {
    e.dids.remove(did);
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _unlistenBus?.call();
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in sessions.values) {
      s.dispose();
    }
    sessions.clear();
    unawaited(tcp.stop());
    core.dispose();
    super.dispose();
  }
}
```

（`_isDiagnostic` は「周期フレームの ID でないもの」をすべて残す。7DF〜7EF と 29bit は明示的に残す。）

- [ ] **Step 5: 実装する（CLI）**

`bin/elm327_tcp.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:elm327emu/app/control_commands.dart';
import 'package:elm327emu/app/emulation_core.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import 'package:elm327emu/transport/tcp_transport.dart';

/// UI なしで ELM327 エミュレータを TCP で待ち受ける（python-OBD などの検証用）。
/// 標準入力 1 行 = 制御コマンド 1 つ（lib/app/control_commands.dart）。
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('port', defaultsTo: '35000')
    ..addFlag('transmission', negatable: false, help: 'トランスミッション ECU を有効にする')
    ..addFlag('dynamic', negatable: false, help: '動的シミュレーションを有効にする')
    ..addFlag('quiet', negatable: false, help: '送受信を表示しない');
  final args = parser.parse(argv);
  final quiet = args['quiet'] as bool;

  final core = EmulationCore()..start();
  core.transmission.enabled = args['transmission'] as bool;
  core.simulator.enabled = args['dynamic'] as bool;
  Timer.periodic(const Duration(milliseconds: 200), (_) => core.simulator.tick(0.2));

  final tcp = TcpTransport(port: int.parse(args['port'] as String));
  ElmSession? session;
  String esc(List<int> b) => String.fromCharCodes(b).replaceAll('\r', r'\r').replaceAll('\n', r'\n');

  tcp.onConnection.listen((state) {
    stdout.writeln('conn $state');
    session?.dispose();
    session = null;
    if (state.startsWith('connected')) {
      final s = core.newSession();
      s.output.listen((b) {
        if (!quiet) stdout.writeln('=> ${esc(b)}');
        tcp.send(b);
      });
      session = s;
    }
  });
  tcp.onReceive.listen((b) {
    if (!quiet) stdout.writeln('<= ${esc(b)}');
    session?.input(b);
  });

  await tcp.start();
  stdout.writeln('listening ${tcp.port}');

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(await applyControl(core, line, disconnect: tcp.disconnect));
  }
  await tcp.stop();
  core.dispose();
  exit(0);
}
```

- [ ] **Step 6: 旧エンジンを削除し、UI の最小修正をする**

```bash
git rm lib/elm327/elm327_engine.dart lib/elm327/at_command_handler.dart lib/elm327/obd_command_handler.dart lib/elm327/obd_encoding.dart test/elm327_engine_test.dart test/at_command_handler_test.dart test/obd_command_handler_test.dart test/obd_encoding_test.dart
```

`lib/vehicle/vehicle_state.dart` から次の 3 行を削除する:

```dart
  // 旧エンジン（Elm327Engine）用。Task 13 で削除する。
  List<String> dtcs = ['P0301'];
  String vin = 'WAUZZZ8K9AA000000';
```

`lib/ui/dtc_editor.dart` の `c.vehicle.dtcs` を使う 3 箇所を置き換える（UI は Task 16 で作り直すまでの間の修正）:
- `children: c.vehicle.dtcs` → `children: c.core.engine.confirmedDtcs`
- `c.vehicle.dtcs.remove(d); c.notify();` → `c.removeDtc(c.core.engine, DtcKind.confirmed, d);`
- `if (RegExp(r'^[PCBU][0-9A-F]{4}$').hasMatch(t)) { c.vehicle.dtcs.add(t); _ctrl.clear(); c.notify(); }` → `if (c.addDtc(c.core.engine, DtcKind.confirmed, t)) _ctrl.clear();`

`lib/ui/home_page.dart` のログ表示を `LogEntry` に合わせる:
- `.map((l) => Text(l, style: …))` → `.map((l) => Text('${l.kind.name} ${l.text}', style: …))`

- [ ] **Step 7: 通ることを確認する**

Run: `flutter analyze && flutter test`
Expected: `No issues found!`、全件 PASS

CLI の動作確認:

Run（別ターミナルでも、バックグラウンドでもよい）:
```bash
dart run bin/elm327_tcp.dart --port 35123 &
sleep 5
python3 - <<'EOF'
import socket, time
s = socket.create_connection(('127.0.0.1', 35123))
s.sendall(b'ATI\r')
time.sleep(0.3)
print(repr(s.recv(1024)))
s.close()
EOF
kill %1
```
Expected: `b'ATI\rELM327 v1.5\r\r>'`

- [ ] **Step 8: コミット**

```bash
git add -A lib bin test
git commit -m "feat: EmulationCore・コントローラ作り直し・開発用TCP・CLI、旧エンジンを削除

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: ネイティブの切断と TCP の許可

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/elm327emu/BleGattServer.kt`, `SppServer.kt`, `Elm327Plugin.kt`
- Modify: `macos/Runner/BleGattServer.swift`, `macos/Runner/Elm327Plugin.swift`, `macos/Runner/Release.entitlements`

**Interfaces:**
- Consumes: `TransportBridge.disconnect`（Task 13。MethodChannel `elm327/control` の `disconnect`、引数 `{'transport': 'ble' | 'spp'}`）
- Produces: ネイティブ側の `disconnect` 実装。Android: BLE は `cancelConnection`、SPP はクライアントソケットだけ閉じて待ち受けは続ける。macOS: サービス削除・広告停止 → 0.5 秒後に登録し直す疑似切断。Release でも TCP サーバを開けるよう `com.apple.security.network.server` を追加。

- [ ] **Step 1: Android を実装する**

`BleGattServer.kt` の `fun stop()` の前に追加:

```kotlin
    /** 接続中のセントラルだけ切る。GATT サーバと広告は続ける。 */
    fun disconnect() {
        val d = device ?: return
        synchronized(pending) {
            pending.clear()
            sending = false
        }
        gattServer?.cancelConnection(d)
    }
```

`SppServer.kt` の `fun stop()` の前に追加:

```kotlin
    /** 接続中のクライアントだけ切る。readLoop が抜けて accept に戻るので待ち受けは続く。 */
    fun disconnect() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
    }
```

`Elm327Plugin.kt` の `"send" -> { … }` の後に追加:

```kotlin
                "disconnect" -> {
                    when (call.argument<String>("transport")) {
                        "ble" -> ble?.disconnect()
                        "spp" -> spp?.disconnect()
                    }
                    result.success(null)
                }
```

- [ ] **Step 2: macOS を実装する**

`BleGattServer.swift` の `func stop()` の前に追加:

```swift
    /// 疑似切断。CoreBluetooth のペリフェラル側には相手を切る API がないため、
    /// サービスを外して広告を止め、0.5 秒後に登録し直す。相手からは「サービスが無効になった」と見える。
    func disconnect() {
        let fff0 = useFff0
        let id = central?.identifier.uuidString ?? ""
        stop()
        onConn("disconnected", id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(useFff0: fff0)
        }
    }
```

`Elm327Plugin.swift` の `case "send":` の前に追加:

```swift
            case "disconnect":
                self.ble?.disconnect()
                result(nil)
```

`macos/Runner/Release.entitlements` の `<dict>` 内に追加:

```xml
	<key>com.apple.security.network.server</key>
	<true/>
```

- [ ] **Step 3: ビルドを確認する**

Run: `flutter build apk --debug && flutter build macos --debug`
Expected: 両方 `✓ Built …`

（実機での切断の確認は Bluetooth 接続が必要なため、この計画では行わない。README のチェックリストに入れる（Task 17）。）

- [ ] **Step 4: コミット**

```bash
git add android/app/src/main/kotlin/com/example/elm327emu/BleGattServer.kt android/app/src/main/kotlin/com/example/elm327emu/SppServer.kt android/app/src/main/kotlin/com/example/elm327emu/Elm327Plugin.kt macos/Runner/BleGattServer.swift macos/Runner/Elm327Plugin.swift macos/Runner/Release.entitlements
git commit -m "feat(native): 接続中の相手だけ切る disconnect（macOS は疑似切断）、Release で TCP を許可

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: UI（外枠・接続タブ・車両タブ・ログタブ）

**Files:**
- Create: `lib/ui/common.dart`, `lib/ui/connection_tab.dart`, `lib/ui/vehicle_fields.dart`, `lib/ui/vehicle_tab.dart`, `lib/ui/log_tab.dart`
- Modify: `lib/ui/home_page.dart`（全置き換え）、`lib/main.dart`（テーマの色）
- Delete: `lib/ui/value_controls.dart`
- Test: `test/support/ui_harness.dart`, `test/ui/home_page_test.dart`（`test/widget_test.dart` はそのまま残す）

**Interfaces:**
- Consumes: `EmulatorController` と `LogKind`, `LogEntry`, `DtcKind`（Task 13）、`ElmState`（Task 7）、`VehicleState`（Task 3）、`hex2`, `hexN`（Task 1）、`EcuProfile`（Task 3）、`FakeTransportBridge`（Task 13）
- Produces:
  - `lib/ui/common.dart`: `class AppColors`（`teal`, `tealLight`, `console`, `consoleText`, `warnBg`, `warnFg`, `danger`, `caption`）、`const monoStyle`, `const captionStyle`、`SectionCard({required String title, required List<Widget> children, Widget? trailing})`、`NoticeBanner({required String title, List<String> lines, bool warn})`、`EcuSelector({required List<EcuProfile> ecus, required String selected, required ValueChanged<String> onChanged})`
  - `ConnectionTab({required VoidCallback onShowLog})`、`ElmStateGrid({required ElmState state})` と `static List<(String, String)> ElmStateGrid.items(ElmState)`
  - `VehicleField`, `final List<VehicleField> vehicleFields`（22 項目、先頭 12 項目が最初に見える）
  - `VehicleTab()`、`LogTab()`、`enum LogFilter`、`bool logMatches(LogFilter, LogEntry)`、`String logLine(LogEntry)`
  - `HomePage()`（この Task ではタブ 3 つ: 接続・車両・ログ。Task 16 で 6 つにする）
  - ウィジェットの Key: `start-ble` / `stop-ble` / `disconnect-ble`（spp・tcp も同様）、`pid-edit-field`

- [ ] **Step 1: 失敗するテストを書く**

`test/support/ui_harness.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/transport/transport.dart';
import 'package:elm327emu/ui/home_page.dart';
import 'fake_bridge.dart';

/// スマホ幅（420×900）で HomePage を表示する。init() は呼ばない（タイマーを動かさない）。
Future<(EmulatorController, FakeTransportBridge)> pumpHome(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final bridge = FakeTransportBridge();
  final c = EmulatorController(bridge: bridge, tcpAvailable: true)
    ..caps = [TransportType.ble, TransportType.spp, TransportType.tcp];
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: c, child: const MaterialApp(home: HomePage())),
  );
  return (c, bridge);
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

/// タブの中の縦スクロールを動かして [target] を画面に出す。
Future<void> reveal(WidgetTester tester, Finder target, Type tab) async {
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find.descendant(of: find.byType(tab), matching: find.byType(Scrollable)).first,
  );
  await tester.pumpAndSettle();
}
```

`test/ui/home_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/ui/connection_tab.dart';
import 'package:elm327emu/ui/vehicle_tab.dart';
import '../support/ui_harness.dart';

void main() {
  testWidgets('タイトル・タブ・接続状態', (tester) async {
    await pumpHome(tester);
    expect(find.text('ELM327 Emulator'), findsOneWidget);
    for (final t in ['接続', '車両', 'ログ']) {
      expect(find.descendant(of: find.byType(TabBar), matching: find.text(t)), findsOneWidget);
    }
    expect(find.text('未接続'), findsOneWidget);
  });

  testWidgets('接続タブ: 3 経路・ELM の状態・開始はブリッジへ', (tester) async {
    final (c, b) = await pumpHome(tester);
    expect(find.text('BLE'), findsOneWidget);
    expect(find.text('SPP'), findsOneWidget);
    expect(find.text('TCP（開発用）'), findsOneWidget);
    expect(find.text('A0 · AUTO'), findsOneWidget);
    expect(find.text('ATSH 7DF'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-ble')));
    await tester.pump();
    expect(b.calls, ['startBle:false']);
    expect(find.text('待ち受け中'), findsOneWidget);
    final disconnect = tester.widget<FilledButton>(find.byKey(const Key('disconnect-ble')));
    expect(disconnect.onPressed, isNull); // 接続中でなければ押せない
  });

  testWidgets('車両タブ: 動的と手動・PID の編集・すべて表示・イグニッション', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, '車両');
    await tester.tap(find.text('動的'));
    await tester.pump();
    expect(c.simulator.enabled, isTrue);
    await tester.tap(find.text('手動'));
    await tester.pump();
    expect(c.simulator.enabled, isFalse);

    await tester.tap(find.text('イグニッション'));
    await tester.pump();
    expect(c.core.faultConfig.ignitionOff, isTrue);

    await reveal(tester, find.text('吸気管圧力'), VehicleTab);
    await tester.tap(find.text('吸気管圧力'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pid-edit-field')), '50');
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(c.vehicle.mapKpa, 50);

    expect(find.text('触媒温度'), findsNothing);
    await reveal(tester, find.text('すべて表示'), VehicleTab);
    await tester.tap(find.text('すべて表示'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('触媒温度'), VehicleTab);
    expect(find.text('触媒温度'), findsOneWidget);
  });

  testWidgets('ログタブ: 表示・絞り込み・クリア', (tester) async {
    final (c, _) = await pumpHome(tester);
    c.log
      ..add(LogEntry(DateTime(2026, 9, 23, 14, 2, 11, 201), LogKind.input, 'ATZ'))
      ..add(LogEntry(DateTime(2026, 9, 23, 14, 2, 11, 845), LogKind.can, 'RX 7E8 [8] 06 41 00'));
    c.notify();
    await openTab(tester, 'ログ');
    expect(find.text('14:02:11.201 ← ATZ'), findsOneWidget);
    await tester.tap(find.text('CAN フレーム'));
    await tester.pump();
    expect(find.text('14:02:11.201 ← ATZ'), findsNothing);
    expect(find.text('14:02:11.845 ≡ RX 7E8 [8] 06 41 00'), findsOneWidget);
    await tester.tap(find.text('クリア'));
    await tester.pump();
    expect(c.log, isEmpty);
    expect(find.text('ログはありません'), findsOneWidget);
  });

  testWidgets('接続タブの「ログをすべて見る」でログタブへ', (tester) async {
    await pumpHome(tester);
    await reveal(tester, find.text('ログをすべて見る'), ConnectionTab);
    await tester.tap(find.text('ログをすべて見る'));
    await tester.pumpAndSettle();
    expect(find.text('自動スクロール'), findsOneWidget);
  });

  test('ElmStateGrid.items', () {
    final s = ElmState()
      ..headers = true
      ..craId = 0x7E9;
    final items = ElmStateGrid.items(s);
    expect(items.map((e) => e.$1), ['プロトコル', '送信ヘッダ', '表示', 'CAN 整形', 'タイムアウト', '受信フィルタ']);
    expect(items[2].$2, 'E1 L0 S1 H1 D0');
    expect(items[3].$2, 'CAF1 · NL');
    expect(items[4].$2, 'ST 32 (200ms) · AT1');
    expect(items[5].$2, 'CRA 7E9');
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/ui/home_page_test.dart`
Expected: FAIL（`connection_tab.dart` などがない）

- [ ] **Step 3: 実装する**

`lib/ui/common.dart`:

```dart
import 'package:flutter/material.dart';

import '../ecu/ecu_profile.dart';
import '../util/hex.dart';

/// 画面案（https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa ）の色。
class AppColors {
  static const teal = Color(0xFF0F5F56);
  static const tealLight = Color(0xFFD5EEE9);
  static const tabInactive = Color(0xFFD3ECE7);
  static const console = Color(0xFF16201D);
  static const consoleText = Color(0xFFDDE7E3);
  static const warnBg = Color(0xFFFCEBC9);
  static const warnFg = Color(0xFF6B4500);
  static const neutralBg = Color(0xFFECEEEC);
  static const tile = Color(0xFFF4F5F2);
  static const danger = Color(0xFFB3261E);
  static const caption = Color(0xFF4A524E);
}

const monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 13);
const captionStyle = TextStyle(fontSize: 12, color: AppColors.caption);

/// 角丸・枠線・見出し付きのカード。
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFD9DDD9)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}

/// 画面上部の注意帯（MIL・有効な障害など）。
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.title, this.lines = const [], this.warn = true});

  final String title;
  final List<String> lines;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final fg = warn ? AppColors.warnFg : AppColors.caption;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: warn ? AppColors.warnBg : AppColors.neutralBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: fg)),
        for (final l in lines) Text(l, style: TextStyle(fontSize: 13, color: fg)),
      ]),
    );
  }
}

/// ECU の切り替え（DTC タブと ECU タブで共通）。
class EcuSelector extends StatelessWidget {
  const EcuSelector({super.key, required this.ecus, required this.selected, required this.onChanged});

  final List<EcuProfile> ecus;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        for (final e in ecus)
          ButtonSegment(
            value: e.name,
            label: Text(e.enabled ? '${e.label} ${hexN(e.responseId11, 3)}' : '${e.label}（無効）'),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
```

`lib/ui/connection_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../elm327/elm_state.dart';
import '../transport/transport.dart';
import '../util/hex.dart';
import 'common.dart';

class ConnectionTab extends StatelessWidget {
  const ConnectionTab({super.key, required this.onShowLog});

  final VoidCallback onShowLog;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final talk = c.log.where((e) => e.kind == LogKind.input || e.kind == LogKind.output).toList();
    final recent = talk.length > 4 ? talk.sublist(talk.length - 4) : talk;
    final consoleText = monoStyle.copyWith(color: AppColors.consoleText, fontSize: 12);
    return ListView(padding: const EdgeInsets.all(16), children: [
      SectionCard(title: 'Bluetooth', children: [
        _TransportRow(
          id: 'ble',
          label: 'BLE',
          note: '広告名 OBDII',
          status: c.statusText(TransportType.ble),
          onStart: c.startBle,
          onStop: c.stopBle,
          onDisconnect: () => c.disconnect(TransportType.ble),
        ),
        Row(children: [
          const Expanded(child: Text('BLE プロファイル')),
          DropdownButton<bool>(
            value: c.useFff0,
            items: const [
              DropdownMenuItem(value: false, child: Text('FFE0 / FFE1')),
              DropdownMenuItem(value: true, child: Text('FFF0 / FFF1 / FFF2')),
            ],
            onChanged: (v) => c.setBleProfile(v ?? false),
          ),
        ]),
        if (c.caps.contains(TransportType.spp)) ...[
          const Divider(height: 24),
          _TransportRow(
            id: 'spp',
            label: 'SPP',
            note: 'Android のみ · UUID 1101',
            status: c.statusText(TransportType.spp),
            onStart: c.startSpp,
            onStop: c.stopSpp,
            onDisconnect: () => c.disconnect(TransportType.spp),
          ),
        ],
        if (c.caps.contains(TransportType.tcp)) ...[
          const Divider(height: 24),
          _TransportRow(
            id: 'tcp',
            label: 'TCP（開発用）',
            note: 'macOS のみ · 127.0.0.1:${c.tcp.port}',
            status: c.statusText(TransportType.tcp),
            onStart: c.startTcp,
            onStop: c.stopTcp,
            onDisconnect: () => c.disconnect(TransportType.tcp),
          ),
        ],
      ]),
      SectionCard(title: 'ELM の現在の状態', children: [ElmStateGrid(state: c.displayState)]),
      SectionCard(title: '最近のやりとり', children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppColors.console, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (recent.isEmpty) Text('まだありません', style: consoleText),
            for (final e in recent)
              Text('${e.kind == LogKind.input ? '←' : '→'} ${e.text}', style: consoleText),
          ]),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onShowLog, child: const Text('ログをすべて見る')),
        ),
      ]),
    ]);
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.id,
    required this.label,
    required this.note,
    required this.status,
    required this.onStart,
    required this.onStop,
    required this.onDisconnect,
  });

  final String id;
  final String label;
  final String note;
  final String status;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = status.startsWith('接続中');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            Text(note, style: captionStyle),
          ]),
        ),
        Chip(
          label: Text(status, style: const TextStyle(fontSize: 12)),
          backgroundColor: connected ? AppColors.tealLight : AppColors.neutralBg,
          side: BorderSide.none,
        ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(key: Key('start-$id'), onPressed: onStart, child: const Text('開始')),
        OutlinedButton(key: Key('stop-$id'), onPressed: onStop, child: const Text('停止')),
        FilledButton(
          key: Key('disconnect-$id'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: connected ? onDisconnect : null,
          child: const Text('切断'),
        ),
      ]),
    ]);
  }
}

/// ELM の AT 設定を 2 列で並べる。
class ElmStateGrid extends StatelessWidget {
  const ElmStateGrid({super.key, required this.state});

  final ElmState state;

  static List<(String, String)> items(ElmState s) {
    String b(bool v) => v ? '1' : '0';
    final width = s.is29bit ? 8 : 3;
    final cra = s.craId;
    final mask = s.maskId;
    final ra = s.receiveAddress;
    final filter = cra != null
        ? 'CRA ${hexN(cra, width)}'
        : mask != null
            ? 'CF ${hexN(s.filterId ?? 0, width)} / CM ${hexN(mask, width)}'
            : ra != null
                ? 'RA ${hex2(ra)}'
                : 'なし';
    return [
      ('プロトコル', '${s.describeProtocolNumber()} · ${s.describeProtocol()}'),
      ('送信ヘッダ', 'ATSH ${hexN(s.txId, width)}'),
      ('表示', 'E${b(s.echo)} L${b(s.linefeed)} S${b(s.spaces)} H${b(s.headers)} D${b(s.dlc)}'),
      ('CAN 整形', 'CAF${b(s.caf)} · ${s.allowLong ? 'AL' : 'NL'}'),
      ('タイムアウト', 'ST ${hex2(s.timeoutHex)} (${s.timeout.inMilliseconds}ms) · AT${s.timing.index}'),
      ('受信フィルタ', filter),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 8) / 2;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (k, v) in items(state))
          Container(
            width: w,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.tile, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k, style: captionStyle.copyWith(fontSize: 11)),
              const SizedBox(height: 2),
              Text(v, style: monoStyle),
            ]),
          ),
      ]);
    });
  }
}
```

`lib/ui/vehicle_fields.dart`:

```dart
import '../vehicle/vehicle_state.dart';

/// 車両タブ「その他の PID」の 1 行。
class VehicleField {
  const VehicleField(this.pid, this.label, this.unit, this.get, this.set, {this.digits = 0});

  final String pid;
  final String label;
  final String unit;
  final double Function(VehicleState v) get;
  final void Function(VehicleState v, double x) set;
  final int digits;

  String format(VehicleState v) => get(v).toStringAsFixed(digits);
}

/// 先頭 12 項目が最初に見える。残りは「すべて表示」で出す。
final List<VehicleField> vehicleFields = [
  VehicleField('0B', '吸気管圧力', 'kPa', (v) => v.mapKpa, (v, x) => v.mapKpa = x),
  VehicleField('0E', '点火時期', '°', (v) => v.timingDeg, (v, x) => v.timingDeg = x, digits: 1),
  VehicleField('0F', '吸気温', '°C', (v) => v.intakeTempC, (v, x) => v.intakeTempC = x),
  VehicleField('10', '空気流量 MAF', 'g/s', (v) => v.maf, (v, x) => v.maf = x, digits: 2),
  VehicleField('06', '短期燃料トリム', '%', (v) => v.stftPct, (v, x) => v.stftPct = x, digits: 1),
  VehicleField('07', '長期燃料トリム', '%', (v) => v.ltftPct, (v, x) => v.ltftPct = x, digits: 1),
  VehicleField('2F', '燃料残量', '%', (v) => v.fuelLevelPct, (v, x) => v.fuelLevelPct = x, digits: 1),
  VehicleField('33', '大気圧', 'kPa', (v) => v.baroKpa, (v, x) => v.baroKpa = x),
  VehicleField('46', '外気温', '°C', (v) => v.ambientTempC, (v, x) => v.ambientTempC = x),
  VehicleField('5C', '油温', '°C', (v) => v.oilTempC, (v, x) => v.oilTempC = x),
  VehicleField('5E', '燃料消費率', 'L/h', (v) => v.fuelRateLph, (v, x) => v.fuelRateLph = x, digits: 1),
  VehicleField('A6', '走行距離計', 'km', (v) => v.odometerKm, (v, x) => v.odometerKm = x, digits: 1),
  VehicleField('1F', '始動後の経過時間', 's', (v) => v.runTimeSec, (v, x) => v.runTimeSec = x),
  VehicleField('21', 'MIL 点灯後の距離', 'km', (v) => v.distanceWithMilKm, (v, x) => v.distanceWithMilKm = x),
  VehicleField('30', '消去後のウォームアップ', '回', (v) => v.warmupsSinceClear.toDouble(),
      (v, x) => v.warmupsSinceClear = x.round()),
  VehicleField('31', '消去後の距離', 'km', (v) => v.distanceSinceClearKm, (v, x) => v.distanceSinceClearKm = x),
  VehicleField('3C', '触媒温度', '°C', (v) => v.catalystTempC, (v, x) => v.catalystTempC = x),
  VehicleField('43', '絶対負荷', '%', (v) => v.absLoadPct, (v, x) => v.absLoadPct = x),
  VehicleField('44', '指令空燃比 λ', '', (v) => v.lambda, (v, x) => v.lambda = x, digits: 3),
  VehicleField('49', 'アクセル開度', '%', (v) => v.acceleratorPct, (v, x) => v.acceleratorPct = x),
  VehicleField('4D', 'MIL 点灯時間', 'min', (v) => v.secondsWithMil / 60, (v, x) => v.secondsWithMil = x * 60),
  VehicleField('4E', '消去後の時間', 'min', (v) => v.secondsSinceClear / 60, (v, x) => v.secondsSinceClear = x * 60),
];
```

`lib/ui/vehicle_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';
import 'vehicle_fields.dart';

class VehicleTab extends StatefulWidget {
  const VehicleTab({super.key});

  @override
  State<VehicleTab> createState() => _VehicleTabState();
}

class _VehicleTabState extends State<VehicleTab> {
  static const _shortCount = 12;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final v = c.vehicle;
    final dynamicMode = c.simulator.enabled;
    final fields = _showAll ? vehicleFields : vehicleFields.take(_shortCount).toList();
    ValueChanged<double>? edit(void Function(double x) apply) => dynamicMode
        ? null
        : (x) {
            apply(x);
            c.notify();
          };
    return ListView(padding: const EdgeInsets.all(16), children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('動的')),
          ButtonSegment(value: false, label: Text('手動')),
        ],
        selected: {dynamicMode},
        onSelectionChanged: (s) => c.setSimEnabled(s.first),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('イグニッション'),
        subtitle: const Text('OFF にすると全 ECU が応答しない', style: captionStyle),
        value: !c.core.faultConfig.ignitionOff,
        onChanged: (on) => c.updateFaults((f) => f.ignitionOff = !on),
      ),
      SectionCard(title: '基本の値', children: [
        Text(
          dynamicMode ? '動的モード中は現在値を表示します。手動にすると編集できます' : 'スライダで値を固定できます',
          style: captionStyle,
        ),
        _ValueSlider(label: '回転数 (0C)', unit: 'rpm', value: v.rpm.toDouble(), min: 0, max: 8000,
            onChanged: edit((x) => v.rpm = x.round())),
        _ValueSlider(label: '車速 (0D)', unit: 'km/h', value: v.speedKmh, min: 0, max: 255,
            onChanged: edit((x) => v.speedKmh = x)),
        _ValueSlider(label: '水温 (05)', unit: '°C', value: v.coolantTempC, min: -40, max: 150,
            onChanged: edit((x) => v.coolantTempC = x)),
        _ValueSlider(label: 'スロットル (11)', unit: '%', value: v.throttlePct, min: 0, max: 100,
            onChanged: edit((x) => v.throttlePct = x)),
        _ValueSlider(label: 'エンジン負荷 (04)', unit: '%', value: v.engineLoadPct, min: 0, max: 100,
            onChanged: edit((x) => v.engineLoadPct = x)),
        _ValueSlider(label: '電圧 (42 / ATRV)', unit: 'V', value: v.batteryVoltage, min: 8, max: 16, digits: 1,
            onChanged: edit((x) => v.batteryVoltage = x)),
      ]),
      SectionCard(
        title: 'その他の PID',
        trailing: TextButton(
          onPressed: () => setState(() => _showAll = !_showAll),
          child: Text(_showAll ? '一部だけ表示' : 'すべて表示'),
        ),
        children: [
          Text(
            '全 ${vehicleFields.length} 項目中 ${fields.length} 項目を表示${dynamicMode ? '' : '（タップで編集）'}',
            style: captionStyle,
          ),
          for (final f in fields)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 28,
                child: Text(f.pid, style: monoStyle.copyWith(color: AppColors.teal, fontSize: 12)),
              ),
              title: Text(f.label),
              trailing: Text('${f.format(v)} ${f.unit}'.trim(), style: monoStyle),
              onTap: dynamicMode
                  ? null
                  : () async {
                      final x = await showDialog<double>(
                        context: context,
                        builder: (_) => _PidEditDialog(field: f, initial: f.format(v)),
                      );
                      if (x != null) {
                        f.set(c.vehicle, x);
                        c.notify();
                      }
                    },
            ),
        ],
      ),
    ]);
  }
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.digits = 0,
  });

  final String label;
  final String unit;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final int digits;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(label)),
        Text('${value.toStringAsFixed(digits)} $unit', style: monoStyle),
      ]),
      Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged),
    ]);
  }
}

class _PidEditDialog extends StatefulWidget {
  const _PidEditDialog({required this.field, required this.initial});

  final VehicleField field;
  final String initial;

  @override
  State<_PidEditDialog> createState() => _PidEditDialogState();
}

class _PidEditDialogState extends State<_PidEditDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    return AlertDialog(
      title: Text(f.unit.isEmpty ? f.label : '${f.label}（${f.unit}）'),
      content: TextField(
        key: const Key('pid-edit-field'),
        controller: _ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(
          onPressed: () => Navigator.pop(context, double.tryParse(_ctrl.text.trim())),
          child: const Text('設定'),
        ),
      ],
    );
  }
}
```

`lib/ui/log_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';

enum LogFilter { all, elm, can, fault }

const _filterLabels = {
  LogFilter.all: 'すべて',
  LogFilter.elm: 'ELM 文字列',
  LogFilter.can: 'CAN フレーム',
  LogFilter.fault: '障害',
};

bool logMatches(LogFilter f, LogEntry e) => switch (f) {
      LogFilter.all => true,
      LogFilter.elm => e.kind == LogKind.input || e.kind == LogKind.output,
      LogFilter.can => e.kind == LogKind.can,
      LogFilter.fault => e.kind == LogKind.fault,
    };

String logLine(LogEntry e) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = e.time;
  final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  const glyph = {
    LogKind.input: '←',
    LogKind.output: '→',
    LogKind.can: '≡',
    LogKind.fault: '!',
    LogKind.info: '·',
  };
  return '$time ${glyph[e.kind]} ${e.text}';
}

class LogTab extends StatefulWidget {
  const LogTab({super.key});

  @override
  State<LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<LogTab> {
  static const _colors = {
    LogKind.input: Color(0xFF7DE0C8),
    LogKind.output: Color(0xFFF2C46D),
    LogKind.can: Color(0xFFC9D4FF),
    LogKind.fault: Color(0xFFFFC9C2),
    LogKind.info: Color(0xFF8A9A94),
  };

  LogFilter _filter = LogFilter.all;
  bool _autoScroll = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final entries = c.log.where((e) => logMatches(_filter, e)).toList();
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in LogFilter.values)
            ChoiceChip(
              label: Text(_filterLabels[f]!),
              selected: _filter == f,
              onSelected: (_) => setState(() => _filter = f),
            ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.console, borderRadius: BorderRadius.circular(14)),
            child: entries.isEmpty
                ? Text('ログはありません', style: monoStyle.copyWith(color: AppColors.consoleText, fontSize: 12))
                : ListView.builder(
                    controller: _scroll,
                    itemCount: entries.length,
                    itemBuilder: (context, i) => Text(
                      logLine(entries[i]),
                      style: monoStyle.copyWith(fontSize: 11.5, height: 1.6, color: _colors[entries[i].kind]),
                    ),
                  ),
          ),
        ),
        Row(children: [
          Checkbox(value: _autoScroll, onChanged: (v) => setState(() => _autoScroll = v ?? true)),
          const Text('自動スクロール'),
          const Spacer(),
          OutlinedButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: entries.map(logLine).join('\n'))),
            child: const Text('コピー'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: c.clearLog, child: const Text('クリア')),
        ]),
      ]),
    );
  }
}
```

`lib/ui/home_page.dart`（全置き換え）:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';
import 'connection_tab.dart';
import 'log_tab.dart';
import 'vehicle_tab.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const tabs = ['接続', '車両', 'ログ'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Builder(builder: (context) {
        final c = context.watch<EmulatorController>();
        return Scaffold(
          backgroundColor: AppColors.tile,
          appBar: AppBar(
            backgroundColor: AppColors.teal,
            foregroundColor: Colors.white,
            title: const Text('ELM327 Emulator'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(label: Text(c.headlineStatus, style: const TextStyle(fontSize: 12))),
              ),
            ],
            bottom: TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: AppColors.tabInactive,
              indicatorColor: Colors.white,
              tabs: [for (final t in tabs) Tab(text: t)],
            ),
          ),
          body: TabBarView(children: [
            ConnectionTab(onShowLog: () => DefaultTabController.of(context).animateTo(tabs.indexOf('ログ'))),
            const VehicleTab(),
            const LogTab(),
          ]),
        );
      }),
    );
  }
}
```

`lib/main.dart` の `theme:` を置き換える:

```dart
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F5F56), useMaterial3: true),
```

- [ ] **Step 4: 通ることを確認する**

Run: `git rm lib/ui/value_controls.dart && flutter analyze && flutter test`
Expected: `No issues found!`、全件 PASS（`test/widget_test.dart` も通る）

- [ ] **Step 5: 実機で表示を見る**

Run: `flutter run -d macos`
3 つのタブを開き、画面案（https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa ）と並べて、見出し・カードの並び・文言・色を 1 要素ずつ照合する。違いがあれば直すか、違う理由を報告に書く。

- [ ] **Step 6: コミット**

```bash
git add lib/ui lib/main.dart test/support/ui_harness.dart test/ui/home_page_test.dart
git commit -m "feat(ui): 外枠と接続・車両・ログタブ

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: UI（DTC タブ・ECU タブ・障害タブ）

**Files:**
- Create: `lib/ui/dtc_tab.dart`, `lib/ui/ecu_tab.dart`, `lib/ui/faults_tab.dart`
- Modify: `lib/ui/home_page.dart`（タブを 6 つに）
- Delete: `lib/ui/dtc_editor.dart`
- Test: `test/ui/tabs_test.dart`

**Interfaces:**
- Consumes: Task 13 の `EmulatorController` の操作すべて、Task 15 の `common.dart`、`pidTable`（Task 4）、`DidValue`（Task 3）、`ElmErrorKind`, `ErrorTrigger`（Task 6）、`parseHexBytes`, `hex2`, `hexN`（Task 1）
- Produces:
  - `DtcTab()`, `EcuTab()`, `FaultsTab()`
  - `HomePage.tabs = ['接続', '車両', 'DTC', 'ECU', '障害', 'ログ']`
  - ウィジェットの Key: `dtc-input-<confirmed|pending|permanent>`, `dtc-add-<…>`, `dtc-clear`, `ecu-enable-<engine|transmission>`, `ecu-vin`, `ecu-calid`, `ecu-cvn`, `ecu-name`, `ecu-save`, `did-add`, `did-id`, `did-value`, `did-ok`, `fault-ignition`, `fault-disconnect`, `fault-silent-<engine|transmission>`, `fault-pending`, `fault-truncate`, `fault-error-fire`, `fault-error-stop`

- [ ] **Step 1: 失敗するテストを書く**

`test/ui/tabs_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ui/dtc_tab.dart';
import 'package:elm327emu/ui/ecu_tab.dart';
import 'package:elm327emu/ui/faults_tab.dart';
import '../support/ui_harness.dart';

void main() {
  testWidgets('タブは 6 つ', (tester) async {
    await pumpHome(tester);
    for (final t in ['接続', '車両', 'DTC', 'ECU', '障害', 'ログ']) {
      expect(find.descendant(of: find.byType(TabBar), matching: find.text(t)), findsOneWidget);
    }
  });

  testWidgets('DTC タブ: 小文字・空白を直して追加・形式違い・削除・消去（Review Focus 5）', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, 'DTC');
    expect(find.text('MIL 点灯中 · 確定 1 件（0101 の応答に反映）'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dtc-input-confirmed')), ' p0420 ');
    await tester.tap(find.byKey(const Key('dtc-add-confirmed')));
    await tester.pump();
    expect(c.core.engine.confirmedDtcs, ['P0301', 'P0420']);

    await reveal(tester, find.byKey(const Key('dtc-add-pending')), DtcTab);
    await tester.enterText(find.byKey(const Key('dtc-input-pending')), 'X1');
    await tester.tap(find.byKey(const Key('dtc-add-pending')));
    await tester.pump();
    expect(find.text('形式が違います（例: P0301）'), findsOneWidget);
    expect(c.core.engine.pendingDtcs, isEmpty);

    await reveal(tester, find.byTooltip('P0420 を削除'), DtcTab);
    await tester.tap(find.byTooltip('P0420 を削除'));
    await tester.pump();
    expect(c.core.engine.confirmedDtcs, ['P0301']);

    await reveal(tester, find.byKey(const Key('dtc-clear')), DtcTab);
    expect(find.textContaining('P0301 を追加した時点の値'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dtc-clear')));
    await tester.pumpAndSettle();
    expect(c.core.engine.confirmedDtcs, isEmpty);
    expect(find.textContaining('保存されていません'), findsOneWidget);
  });

  testWidgets('ECU タブ: 有効化・Mode 09 の検証と保存・DID の追加', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, 'ECU');
    await tester.tap(find.byKey(const Key('ecu-enable-transmission')));
    await tester.pump();
    expect(c.core.transmission.enabled, isTrue);

    await reveal(tester, find.byKey(const Key('ecu-vin')), EcuTab);
    await tester.enterText(find.byKey(const Key('ecu-vin')), 'SHORT');
    await reveal(tester, find.byKey(const Key('ecu-save')), EcuTab);
    await tester.tap(find.byKey(const Key('ecu-save')));
    await tester.pump();
    expect(find.textContaining('VIN は 17 文字'), findsOneWidget);
    expect(c.core.engine.vin, 'WAUZZZ8K9AA000000');

    await reveal(tester, find.byKey(const Key('ecu-vin')), EcuTab);
    await tester.enterText(find.byKey(const Key('ecu-vin')), 'JT2BF22K1W0123456');
    await reveal(tester, find.byKey(const Key('ecu-save')), EcuTab);
    await tester.tap(find.byKey(const Key('ecu-save')));
    await tester.pump();
    expect(c.core.engine.vin, 'JT2BF22K1W0123456');
    expect(find.text('保存しました'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('did-add')), EcuTab);
    await tester.tap(find.byKey(const Key('did-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('did-id')), 'f1a0');
    await tester.enterText(find.byKey(const Key('did-value')), 'HELLO');
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pumpAndSettle();
    expect(c.core.engine.dids[0xF1A0]!.display, 'HELLO');

    await tester.tap(find.byKey(const Key('did-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('did-id')), 'XYZ');
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pump();
    expect(find.text('DID は 16 進 4 桁'), findsOneWidget);
  });

  testWidgets('障害タブ: イグニッション・遅延の注意・エラー・切断ボタン', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, '障害');
    expect(find.text('有効な障害はありません'), findsOneWidget);
    final disconnect = tester.widget<FilledButton>(find.byKey(const Key('fault-disconnect')));
    expect(disconnect.onPressed, isNull);

    await tester.tap(find.byKey(const Key('fault-ignition')));
    await tester.pump();
    expect(c.core.faultConfig.ignitionOff, isTrue);
    expect(find.text('有効な障害 1 件'), findsOneWidget);

    c.updateFaults((f) => f.delayMs = 350);
    await tester.pump();
    await reveal(tester, find.text('ATST 200ms を超えるため、今は NO DATA になります'), FaultsTab);

    await reveal(tester, find.byKey(const Key('fault-error-fire')), FaultsTab);
    await tester.tap(find.byKey(const Key('fault-error-fire')));
    await tester.pump();
    expect(c.core.faultConfig.errorArmed, isTrue);
    expect(c.core.faultConfig.error, ElmErrorKind.canError);
    await tester.tap(find.byKey(const Key('fault-error-stop')));
    await tester.pump();
    expect(c.core.faultConfig.errorArmed, isFalse);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/ui/tabs_test.dart`
Expected: FAIL（`dtc_tab.dart` などがない）

- [ ] **Step 3: 実装する**

`lib/ui/dtc_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../ecu/ecu_profile.dart';
import '../ecu/pid_table.dart';
import '../util/hex.dart';
import 'common.dart';

class DtcTab extends StatefulWidget {
  const DtcTab({super.key});

  @override
  State<DtcTab> createState() => _DtcTabState();
}

class _DtcTabState extends State<DtcTab> {
  String _ecu = 'engine';

  static String _time(DateTime t) =>
      [t.hour, t.minute, t.second].map((n) => n.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final e = c.core.ecuByName(_ecu);
    final ff = e.freezeFrame;
    final count = e.confirmedDtcs.length;
    return ListView(padding: const EdgeInsets.all(16), children: [
      EcuSelector(ecus: c.core.ecus, selected: _ecu, onChanged: (n) => setState(() => _ecu = n)),
      const SizedBox(height: 14),
      NoticeBanner(
        warn: count > 0,
        title: count == 0 ? 'MIL 消灯 · 確定 0 件' : 'MIL 点灯中 · 確定 $count 件（0101 の応答に反映）',
      ),
      const SizedBox(height: 14),
      _DtcSection(key: ValueKey('confirmed-$_ecu'), kind: DtcKind.confirmed, title: '確定 DTC（Mode 03）', ecu: e),
      _DtcSection(key: ValueKey('pending-$_ecu'), kind: DtcKind.pending, title: '保留 DTC（Mode 07）', ecu: e),
      _DtcSection(
        key: ValueKey('permanent-$_ecu'),
        kind: DtcKind.permanent,
        title: '永続 DTC（Mode 0A）',
        ecu: e,
        note: 'Mode 04 では消えません（規格どおり）',
      ),
      SectionCard(
        title: 'フリーズフレーム（Mode 02）',
        children: ff == null
            ? const [Text('保存されていません（確定 DTC を追加すると、その時点の値を保存します）', style: captionStyle)]
            : [
                Text('${ff.dtc} を追加した時点の値 · ${_time(ff.capturedAt)}（生バイト）', style: captionStyle),
                for (final pid in ff.pids.keys.toList()..sort())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      SizedBox(
                        width: 28,
                        child: Text(hex2(pid), style: monoStyle.copyWith(color: AppColors.teal, fontSize: 12)),
                      ),
                      Expanded(child: Text(pidTable[pid]?.label ?? '')),
                      Text(ff.pids[pid]!.map(hex2).join(' '), style: monoStyle),
                    ]),
                  ),
              ],
      ),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          key: const Key('dtc-clear'),
          onPressed: () => c.clearDtcs(e),
          child: const Text('DTC を消去（Mode 04 と同じ）'),
        ),
      ),
    ]);
  }
}

class _DtcSection extends StatefulWidget {
  const _DtcSection({super.key, required this.kind, required this.title, required this.ecu, this.note});

  final DtcKind kind;
  final String title;
  final EcuProfile ecu;
  final String? note;

  @override
  State<_DtcSection> createState() => _DtcSectionState();
}

class _DtcSectionState extends State<_DtcSection> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<String> get _codes => switch (widget.kind) {
        DtcKind.confirmed => widget.ecu.confirmedDtcs,
        DtcKind.pending => widget.ecu.pendingDtcs,
        DtcKind.permanent => widget.ecu.permanentDtcs,
      };

  void _add(EmulatorController c) {
    if (c.addDtc(widget.ecu, widget.kind, _ctrl.text)) {
      _ctrl.clear();
      setState(() => _error = null);
    } else {
      setState(() => _error = '形式が違います（例: P0301）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final name = widget.kind.name;
    return SectionCard(title: widget.title, children: [
      if (_codes.isEmpty)
        const Text('なし', style: captionStyle)
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final code in _codes)
            InputChip(
              label: Text(code, style: monoStyle),
              onDeleted: () => c.removeDtc(widget.ecu, widget.kind, code),
              deleteButtonTooltipMessage: '$code を削除',
            ),
        ]),
      if (widget.note != null) ...[const SizedBox(height: 6), Text(widget.note!, style: captionStyle)],
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextField(
            key: Key('dtc-input-$name'),
            controller: _ctrl,
            style: monoStyle,
            decoration: InputDecoration(
              hintText: '例: P0301',
              errorText: _error,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _add(c),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(key: Key('dtc-add-$name'), onPressed: () => _add(c), child: const Text('追加')),
      ]),
    ]);
  }
}
```

`lib/ui/ecu_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../ecu/ecu_profile.dart';
import '../util/hex.dart';
import 'common.dart';

class EcuTab extends StatefulWidget {
  const EcuTab({super.key});

  @override
  State<EcuTab> createState() => _EcuTabState();
}

class _EcuTabState extends State<EcuTab> {
  String _ecu = 'engine';
  String? _loadedFor;
  final _vin = TextEditingController();
  final _calid = TextEditingController();
  final _cvn = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    for (final c in [_vin, _calid, _cvn, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(EcuProfile e) {
    _vin.text = e.vin;
    _calid.text = e.calid;
    _cvn.text = e.cvn.map(hex2).join();
    _name.text = e.ecuName;
    _error = null;
    _saved = false;
    _loadedFor = e.name;
  }

  void _save(EmulatorController c, EcuProfile e) {
    final err = c.updateEcuInfo(e,
        vin: _vin.text.trim(), calid: _calid.text, cvnHex: _cvn.text.trim(), name: _name.text.trim());
    setState(() {
      _error = err;
      _saved = err == null;
    });
  }

  Widget _field(String label, TextEditingController ctrl, String key, {int? maxLength, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('ecu-$key'),
        controller: ctrl,
        maxLength: maxLength,
        style: monoStyle,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final e = c.core.ecuByName(_ecu);
    if (_loadedFor != e.name) _load(e);
    final dids = e.dids.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return ListView(padding: const EdgeInsets.all(16), children: [
      SectionCard(title: '応答する ECU', children: [
        for (final p in c.core.ecus)
          SwitchListTile(
            key: Key('ecu-enable-${p.name}'),
            contentPadding: EdgeInsets.zero,
            title: Text(p.label, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              '11bit ${hexN(p.requestId11, 3)} → ${hexN(p.responseId11, 3)}　'
              '29bit ${hexN(p.requestId29, 8)} → ${hexN(p.responseId29For(0xF1), 8)}',
              style: monoStyle.copyWith(fontSize: 12, color: AppColors.caption),
            ),
            value: p.enabled,
            onChanged: (v) => c.setEcuEnabled(p, v),
          ),
      ]),
      EcuSelector(ecus: c.core.ecus, selected: _ecu, onChanged: (n) => setState(() => _ecu = n)),
      const SizedBox(height: 14),
      SectionCard(title: '車両情報（Mode 09）', children: [
        _field('VIN (02)', _vin, 'vin', maxLength: 17),
        _field('CALID (04)', _calid, 'calid', maxLength: 16),
        _field('CVN (06)', _cvn, 'cvn', hint: '16 進 8 桁'),
        _field('ECU 名 (0A)', _name, 'name', maxLength: 20),
        if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
        if (_saved) const Text('保存しました', style: captionStyle),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(key: const Key('ecu-save'), onPressed: () => _save(c, e), child: const Text('保存')),
        ),
      ]),
      SectionCard(title: 'Mode 22 の DID', children: [
        for (final entry in dids)
          Row(children: [
            SizedBox(width: 52, child: Text(hexN(entry.key, 4), style: monoStyle.copyWith(color: AppColors.teal))),
            SizedBox(width: 54, child: Text(entry.value.isAscii ? 'ASCII' : 'HEX', style: captionStyle)),
            Expanded(child: Text(entry.value.display, style: monoStyle, overflow: TextOverflow.ellipsis)),
            IconButton(
              tooltip: '${hexN(entry.key, 4)} を削除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => c.removeDid(e, entry.key),
            ),
          ]),
        Row(children: [
          const Expanded(child: Text('未登録の DID には 7F 22 31 を返します', style: captionStyle)),
          FilledButton.tonal(
            key: const Key('did-add'),
            onPressed: () async {
              final r = await showDialog<(int, DidValue)>(context: context, builder: (_) => const _DidDialog());
              if (r != null) c.setDid(e, r.$1, r.$2);
            },
            child: const Text('DID を追加'),
          ),
        ]),
      ]),
    ]);
  }
}

class _DidDialog extends StatefulWidget {
  const _DidDialog();

  @override
  State<_DidDialog> createState() => _DidDialogState();
}

class _DidDialogState extends State<_DidDialog> {
  static final _didPattern = RegExp(r'^[0-9A-F]{4}$');
  static final _printable = RegExp(r'^[\x20-\x7E]+$');

  final _did = TextEditingController();
  final _value = TextEditingController();
  bool _ascii = true;
  String? _error;

  @override
  void dispose() {
    _did.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final didText = _did.text.trim().toUpperCase();
    if (!_didPattern.hasMatch(didText)) {
      setState(() => _error = 'DID は 16 進 4 桁');
      return;
    }
    final DidValue value;
    if (_ascii) {
      if (!_printable.hasMatch(_value.text)) {
        setState(() => _error = '値は表示可能な ASCII 1 文字以上');
        return;
      }
      value = DidValue.ascii(_value.text);
    } else {
      final bytes = parseHexBytes(_value.text.replaceAll(' ', ''));
      if (bytes == null) {
        setState(() => _error = '値は 16 進（例 0A 1B）');
        return;
      }
      value = DidValue.hex(bytes);
    }
    Navigator.pop(context, (int.parse(didText, radix: 16), value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DID を追加'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(key: const Key('did-id'), controller: _did, decoration: const InputDecoration(labelText: 'DID（16 進 4 桁）')),
        Row(children: [
          const Text('形式'),
          const SizedBox(width: 12),
          DropdownButton<bool>(
            value: _ascii,
            items: const [
              DropdownMenuItem(value: true, child: Text('ASCII')),
              DropdownMenuItem(value: false, child: Text('HEX')),
            ],
            onChanged: (v) => setState(() => _ascii = v ?? true),
          ),
        ]),
        TextField(
          key: const Key('did-value'),
          controller: _value,
          decoration: InputDecoration(labelText: _ascii ? '値（ASCII）' : '値（16 進、例 0A 1B）'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(key: const Key('did-ok'), onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}
```

`lib/ui/faults_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../can/fault_injector.dart';
import '../util/hex.dart';
import 'common.dart';

class FaultsTab extends StatelessWidget {
  const FaultsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final f = c.core.faultConfig;
    final active = c.activeFaultDescriptions();
    final timeoutMs = c.displayState.timeout.inMilliseconds;
    final engineLatency = c.core.engine.baseLatency.inMilliseconds;
    return ListView(padding: const EdgeInsets.all(16), children: [
      NoticeBanner(
        warn: active.isNotEmpty,
        title: active.isEmpty ? '有効な障害はありません' : '有効な障害 ${active.length} 件',
        lines: active,
      ),
      const SizedBox(height: 14),
      SectionCard(title: '接続', children: [
        SwitchListTile(
          key: const Key('fault-ignition'),
          contentPadding: EdgeInsets.zero,
          title: const Text('イグニッション OFF'),
          subtitle: const Text('UNABLE TO CONNECT / CAN ERROR', style: captionStyle),
          value: f.ignitionOff,
          onChanged: (v) => c.updateFaults((x) => x.ignitionOff = v),
        ),
        const Divider(),
        Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('接続を切る'),
              Text('macOS は疑似的な切断（サービスの再登録）', style: captionStyle),
            ]),
          ),
          FilledButton(
            key: const Key('fault-disconnect'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: c.connectedTransports.isEmpty ? null : c.disconnectAll,
            child: const Text('今すぐ切断'),
          ),
        ]),
      ]),
      SectionCard(title: 'ECU の無応答', children: [
        for (final p in c.core.ecus)
          SwitchListTile(
            key: Key('fault-silent-${p.name}'),
            contentPadding: EdgeInsets.zero,
            title: Text('${p.label} ${hexN(p.responseId11, 3)}'),
            subtitle: p.enabled ? null : const Text('ECU が無効のため対象外', style: captionStyle),
            value: f.silentEcus.contains(p.name),
            onChanged: (v) => c.updateFaults((x) => v ? x.silentEcus.add(p.name) : x.silentEcus.remove(p.name)),
          ),
      ]),
      SectionCard(title: 'タイミングと欠落', children: [
        _FaultSlider(
          label: '応答の遅延',
          unit: 'ms',
          value: f.delayMs,
          max: 2000,
          divisions: 40,
          note: f.delayMs + engineLatency > timeoutMs ? 'ATST ${timeoutMs}ms を超えるため、今は NO DATA になります' : null,
          onCommit: (v) => c.updateFaults((x) => x.delayMs = v),
        ),
        _FaultSlider(
          label: 'ランダムな欠落',
          unit: '%',
          value: f.dropPercent,
          max: 100,
          divisions: 20,
          onCommit: (v) => c.updateFaults((x) => x.dropPercent = v),
        ),
        SwitchListTile(
          key: const Key('fault-pending'),
          contentPadding: EdgeInsets.zero,
          title: const Text('応答保留（7F xx 78）'),
          subtitle: const Text('ECU 指定の要求に 7F xx 78 を返し、1 秒後に本応答', style: captionStyle),
          value: f.responsePending,
          onChanged: (v) => c.updateFaults((x) => x.responsePending = v),
        ),
        SwitchListTile(
          key: const Key('fault-truncate'),
          contentPadding: EdgeInsets.zero,
          title: const Text('複数フレームの途中欠落'),
          subtitle: const Text('最初のフレームだけ返す', style: captionStyle),
          value: f.truncateMultiFrame,
          onChanged: (v) => c.updateFaults((x) => x.truncateMultiFrame = v),
        ),
      ]),
      SectionCard(title: 'エラー応答', children: [
        Row(children: [
          const Text('返すエラー'),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<ElmErrorKind>(
              isExpanded: true,
              value: f.error ?? ElmErrorKind.canError,
              items: [
                for (final k in ElmErrorKind.values)
                  DropdownMenuItem(value: k, child: Text(k.text, style: monoStyle)),
              ],
              onChanged: (k) => c.updateFaults((x) => x.error = k),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        SegmentedButton<ErrorTrigger>(
          segments: const [
            ButtonSegment(value: ErrorTrigger.once, label: Text('次の1回だけ')),
            ButtonSegment(value: ErrorTrigger.always, label: Text('常に')),
          ],
          selected: {f.errorTrigger},
          onSelectionChanged: (s) => c.updateFaults((x) => x.errorTrigger = s.first),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (f.errorArmed)
            OutlinedButton(
              key: const Key('fault-error-stop'),
              onPressed: () => c.updateFaults((x) => x.errorArmed = false),
              child: const Text('止める'),
            ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('fault-error-fire'),
            onPressed: () => c.updateFaults((x) {
              x.error ??= ElmErrorKind.canError;
              x.errorArmed = true;
            }),
            child: const Text('エラーを起こす'),
          ),
        ]),
      ]),
    ]);
  }
}

/// ドラッグ中は表示だけ変え、離したときに設定へ反映する（ログが溢れないように）。
class _FaultSlider extends StatefulWidget {
  const _FaultSlider({
    required this.label,
    required this.unit,
    required this.value,
    required this.max,
    required this.divisions,
    required this.onCommit,
    this.note,
  });

  final String label;
  final String unit;
  final int value;
  final int max;
  final int divisions;
  final ValueChanged<int> onCommit;
  final String? note;

  @override
  State<_FaultSlider> createState() => _FaultSliderState();
}

class _FaultSliderState extends State<_FaultSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final shown = (_dragging ?? widget.value.toDouble()).round();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(widget.label)),
        Text('$shown ${widget.unit}', style: monoStyle),
      ]),
      Slider(
        value: shown.toDouble(),
        max: widget.max.toDouble(),
        divisions: widget.divisions,
        label: '$shown${widget.unit}',
        onChanged: (x) => setState(() => _dragging = x),
        onChangeEnd: (x) {
          setState(() => _dragging = null);
          widget.onCommit(x.round());
        },
      ),
      if (widget.note != null) Text(widget.note!, style: captionStyle),
    ]);
  }
}
```

`lib/ui/home_page.dart` を 6 タブにする（Task 15 のファイルの 2 箇所を置き換える）:

```dart
  static const tabs = ['接続', '車両', 'DTC', 'ECU', '障害', 'ログ'];
```

```dart
          body: TabBarView(children: [
            ConnectionTab(onShowLog: () => DefaultTabController.of(context).animateTo(tabs.indexOf('ログ'))),
            const VehicleTab(),
            const DtcTab(),
            const EcuTab(),
            const FaultsTab(),
            const LogTab(),
          ]),
```

import に `dtc_tab.dart`, `ecu_tab.dart`, `faults_tab.dart` を足す（ラベルは 2〜3 文字なので 420px 幅でもスクロールなしで収まる）。

- [ ] **Step 4: 通ることを確認する**

Run: `git rm lib/ui/dtc_editor.dart && flutter analyze && flutter test`
Expected: `No issues found!`、全件 PASS

- [ ] **Step 5: 実機で表示を見る**

Run: `flutter run -d macos`（Android 実機があれば `flutter run -d <id>` も）
6 つのタブを画面案と 1 要素ずつ照合する（見出し・カードの並び・文言・色・スイッチの状態）。違いは直すか、理由を報告に書く。

- [ ] **Step 6: コミット**

```bash
git add lib/ui test/ui/tabs_test.dart
git commit -m "feat(ui): DTC・ECU・障害タブ（6タブ構成）

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: python-OBD による端から端までの確認と README

**Files:**
- Create: `tool/python_obd_check/check.py`, `tool/python_obd_check/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `bin/elm327_tcp.dart` とその制御コマンド（Task 13）
- Produces: `uv run --with obd==0.7.3 python tool/python_obd_check/check.py` で全シナリオを実行し、`PASS` / `FAIL` を 1 行ずつ出して、失敗があれば終了コード 1。

- [ ] **Step 1: 検証スクリプトを書く**

`tool/python_obd_check/check.py`:

```python
"""python-OBD 0.7.3 で bin/elm327_tcp.dart を端から端まで確かめる。

実行: uv run --with obd==0.7.3 python tool/python_obd_check/check.py
"""
import pathlib
import subprocess
import sys

import obd
from obd import OBDStatus

ROOT = pathlib.Path(__file__).resolve().parents[2]
results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)


class Emulator:
    def __init__(self, port, *flags):
        self.port = port
        self.proc = subprocess.Popen(
            ["dart", "run", "bin/elm327_tcp.dart", "--port", str(port), "--quiet", *flags],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        for line in self.proc.stdout:
            if line.startswith("listening"):
                return
        raise RuntimeError("エミュレータが起動しなかった")

    def control(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("エミュレータが終了した")
            if line.startswith("ok"):
                return
            if line.startswith("error"):
                raise RuntimeError(line.strip())

    def close(self):
        self.proc.stdin.close()
        self.proc.terminate()
        self.proc.wait(10)


def connect(port, protocol=None):
    return obd.OBD(f"socket://127.0.0.1:{port}", protocol=protocol, timeout=1.0, fast=True)


def value(r):
    return None if r.is_null() else r.value.magnitude


def scenario_normal():
    emu = Emulator(35101)
    try:
        c = connect(35101)
        check("正常: CAR_CONNECTED", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        check("正常: プロトコル 6", c.protocol_id() == "6", c.protocol_id())
        check("正常: 対応コマンド 30 個以上", len(c.supported_commands) >= 30, str(len(c.supported_commands)))
        check("正常: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        check("正常: SPEED 0", value(c.query(obd.commands.SPEED)) == 0)
        check("正常: COOLANT 85", value(c.query(obd.commands.COOLANT_TEMP)) == 85)
        emu.control("rpm 2150")
        check("正常: RPM の変更が反映（2150）", value(c.query(obd.commands.RPM)) == 2150)
        r = c.query(obd.commands.VIN)
        check("正常: VIN", "WAUZZZ8K9AA000000" in str(r.value), str(r.value))
        r = c.query(obd.commands.GET_DTC)
        check("正常: DTC に P0301", any(code == "P0301" for code, _ in (r.value or [])), str(r.value))
        c.query(obd.commands.CLEAR_DTC)
        r = c.query(obd.commands.GET_DTC)
        check("正常: 消去後の DTC は空", r.value == [], str(r.value))
        r = c.query(obd.commands.ELM_VOLTAGE)
        check("正常: ELM_VOLTAGE 12.4", value(r) is not None and abs(value(r) - 12.4) < 0.05, str(r.value))
        c.close()
    finally:
        emu.close()


def scenario_faults():
    emu = Emulator(35102)
    try:
        c = connect(35102)
        check("障害: 接続", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        emu.control("delay 350")
        check("障害: 遅延 350ms → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("delay 0")
        check("障害: 遅延の解除で戻る", value(c.query(obd.commands.RPM)) == 800)
        emu.control("silent engine on")
        check("障害: エンジン無応答 → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("silent engine off")
        emu.control("error canError once")
        check("障害: CAN ERROR（1 回）→ 値なし", c.query(obd.commands.RPM).is_null())
        check("障害: 次の要求は戻る", value(c.query(obd.commands.RPM)) == 800)
        emu.control("drop 100")
        check("障害: 欠落 100% → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("drop 0")
        emu.control("disconnect")
        c.query(obd.commands.RPM)
        check("障害: 切断で NOT_CONNECTED", c.status() == OBDStatus.NOT_CONNECTED, str(c.status()))
    finally:
        emu.close()


def scenario_ignition_off():
    emu = Emulator(35103)
    try:
        emu.control("ignition off")
        c = connect(35103)
        check("イグニッション OFF: OBD_CONNECTED 止まり", c.status() == OBDStatus.OBD_CONNECTED, str(c.status()))
        c.close()
    finally:
        emu.close()


def scenario_two_ecus():
    emu = Emulator(35104, "--transmission")
    try:
        c = connect(35104)
        check("ECU 2 台: 接続", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        check("ECU 2 台: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        c.close()
    finally:
        emu.close()


def scenario_29bit():
    emu = Emulator(35105)
    try:
        c = connect(35105, protocol="7")
        check("29bit: プロトコル 7", c.protocol_id() == "7", c.protocol_id())
        check("29bit: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        c.close()
    finally:
        emu.close()


if __name__ == "__main__":
    for s in (scenario_normal, scenario_faults, scenario_ignition_off, scenario_two_ecus, scenario_29bit):
        try:
            s()
        except Exception as e:  # シナリオの途中で落ちても残りは続ける
            check(f"{s.__name__} が例外なく終わる", False, repr(e))
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)} passed / {len(failed)} failed")
    sys.exit(1 if failed else 0)
```

`tool/python_obd_check/README.md`:

```markdown
# python-OBD による確認

オープンソースの OBD クライアント python-OBD（0.7.3）を、UI なしのエミュレータ（`bin/elm327_tcp.dart`）へ TCP でつなぎ、
接続・PID の読み取り・DTC の読み取りと消去・障害時の振る舞いを確かめる。

    uv run --with obd==0.7.3 python tool/python_obd_check/check.py

シナリオごとに別のポート（35101〜35105）でエミュレータを起動し、標準入力の制御コマンド（`delay 350` など）で障害を切り替える。
```

- [ ] **Step 2: 実行する**

Run: `uv run --with obd==0.7.3 python tool/python_obd_check/check.py`
Expected: 全行 `PASS`、最後に `N passed / 0 failed`

`FAIL` が出たら、エミュレータとクライアントのどちらが仕様と違うかを、データシートと python-OBD のソース（`obd/elm327.py`、`obd/protocols/protocol_can.py`）で確かめてから直す。python-OBD 側の都合に合わせるためだけに ELM の挙動を変えない。

- [ ] **Step 3: README を更新する**

`README.md` を次の構成に書き換える（既存の「ビルド / 実行」「BLE / SPP の接続情報」は残す）:

- 冒頭の説明に「仮想 CAN バス上の ECU 2 台（エンジン・トランスミッション）、AT コマンド全項目、障害注入」を足す
- **アーキテクチャ**: 設計書 §3 の図
- **対応範囲**: プロトコル（CAN 6〜9 のみ）、Mode 01（38 PID）/02/03/04/06/07/09/0A、Mode 22 と否定応答、AT コマンドは設計書 §5 へのリンク
- **UI**: 6 タブの説明（接続・車両・DTC・ECU・障害・ログ）
- **開発用 TCP と CLI**: `dart run bin/elm327_tcp.dart --port 35000 [--transmission] [--dynamic] [--quiet]` と制御コマンドの一覧（`lib/app/control_commands.dart` の先頭コメントと同じ）
- **python-OBD での確認**: `tool/python_obd_check/README.md` へのリンク
- **既知の制約**:
  - CAN 以外のプロトコルは再現しない
  - macOS の切断は疑似的（サービスの再登録）
  - 未確認の前提（設計書 §1 の 1〜6、計画の変更点 3・8・9）
  - Mode 06 の TID・単位 ID は SAE J1979 と照合していない
- **テスト**: `flutter test`（`dart test` ではない）
- **手動結合確認チェックリスト**: 既存の 4 項目に次を足す
  - [ ] (5) Torque / Car Scanner で接続し、PID の表示・DTC の読み取りと消去ができる
  - [ ] (6) 障害タブの「今すぐ切断」でクライアントが切断を検知する（Android BLE / SPP / macOS BLE それぞれ）
  - [ ] (7) 障害タブのイグニッション OFF で、クライアントが「車両と接続できない」と表示する
  - [ ] (8) トランスミッションを有効にし、クライアントが ECU 2 台を認識する

- [ ] **Step 4: コミット**

```bash
git add tool/python_obd_check README.md
git commit -m "test: python-OBD で端から端まで確かめるスクリプト、README 更新

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 18: 最終確認

**Files:** なし（確認と報告のみ）

- [ ] **Step 1: 全体を確かめる**

Run:
```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build macos --debug
uv run --with obd==0.7.3 python tool/python_obd_check/check.py
```
Expected: 解析エラーなし、テスト全件 PASS、両ビルド成功、python-OBD 全シナリオ PASS

- [ ] **Step 2: 設計書と 1 項目ずつ照合する**

設計書を開き、次の表を 1 行ずつ埋める（「テスト名」はそれを確かめているテスト、なければ「なし」と書いて理由を添える）:
- §5 の AT コマンドの全行 → `test/elm327/at_commands_test.dart` のどのテストか
- §6.2 の PID の全行 → `test/ecu/pid_table_test.dart`
- §6.3・§6.4 の全行 → `test/ecu/obd_services_test.dart`, `test/ecu/uds_services_test.dart`, `test/elm327/elm_session_test.dart`
- §7.1 の全行 → `test/elm327/response_formatter_test.dart`
- §7.2 の全行 → `test/elm327/elm_session_test.dart` の「障害」グループと python-OBD の結果
- §9 の UI の全行 → `test/ui/*` と実機で見た結果

- [ ] **Step 3: わざと壊して確かめる（抜き取り）**

次の 3 つを 1 つずつ一時的に入れて、該当テストが FAIL することを確かめてから戻す:
1. `lib/ecu/pid_table.dart` の `temp40` を `c + 41` にする → 水温・吸気温のテストが FAIL
2. `lib/elm327/response_formatter.dart` で H1 のときもパディングを除く → H1 のテストが FAIL
3. `lib/ecu/ecu.dart` の `_send` で `_remaining` の登録を `bus.transmit` の後に移す → 複数フレームのテストが FAIL（FC が先に届くため）

- [ ] **Step 4: 報告する**

ユーザーへの報告には次を入れる:
- できたことと、設計書との差（「設計書からの変更点」の 11 項目と、その根拠）
- 既存テストの期待値を変えたもの（「既存テストの期待値のうち変わるもの」の表）
- 未確認のまま実装した前提（設計書 §1 の 1〜6、変更点 3・8・9）
- 実機でしか確かめられないもの（README のチェックリスト 1〜8）が未確認であること
- テスト・ビルド・python-OBD の実行結果（件数とコマンド）
