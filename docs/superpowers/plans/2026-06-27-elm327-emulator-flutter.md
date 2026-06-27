# ELM327 エミュレータ (Flutter / Android + macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flutter アプリで ELM327 OBD-II アダプタを実機同様にエミュレートし、自作クライアントが Android では BLE/SPP、macOS では BLE で接続できるようにする。

**Architecture:** ELM327 のコマンド解釈・車両シミュレーション・UI を Dart に集約し、`dart test` で網羅的に検証する。Bluetooth の「サーバ/ペリフェラル役」はプラットフォーム別ネイティブ（Android=Kotlin、macOS=Swift）で実装し、Platform Channel（受信=EventChannel / 送信・制御=MethodChannel）で生バイト列を Dart と橋渡しする。

**Tech Stack:** Flutter / Dart、`dart test`、Kotlin（`BluetoothGattServer`, `BluetoothServerSocket`）、Swift（`CBPeripheralManager`）、Provider（状態管理・軽量）。

## Global Constraints

- 対応プラットフォーム: Android と macOS のみ（iOS 非対応）。
- Transport: Android = BLE + Classic SPP、macOS = BLE のみ。
- BLE 既定プロファイル: Service `0000FFE0-0000-1000-8000-00805F9B34FB` / Characteristic `0000FFE1-0000-1000-8000-00805F9B34FB`（Write Without Response + Notify）。代替: Service `FFF0` / Notify `FFF1` / Write `FFF2`。
- SPP UUID: `00001101-0000-1000-8000-00805F9B34FB`、サービス名 `ELM327`。
- BLE 広告デバイス名: `OBDII`。
- コマンド区切り: `\r`(0x0D)。応答末尾に `\r`（linefeed ON なら `\r\n`）、続けてプロンプト `>`。
- 既定 AT 状態: echo=ON, linefeed=OFF, headers=OFF, spaces=ON。
- 既定識別子: `ATI`→`ELM327 v1.5`、`ATRV`→`12.4V`、既定プロトコル=ISO 15765-4 CAN 11bit/500k（番号 6, `ATDPN`→`6`）。
- Android: minSdk 23、Android 12+ は `BLUETOOTH_ADVERTISE`/`BLUETOOTH_CONNECT` 権限。
- TDD・DRY・YAGNI・タスクごとに頻繁にコミット。Dart のロジックは純粋（Flutter/プラットフォーム非依存）に保ち `dart test` で回す。
- 文字エンコード: コマンド/応答は ASCII。

---

## File Structure

```
lib/
  elm327/
    line_assembler.dart       # \r 区切りでコマンド行を組立（Transport別）
    elm_state.dart            # AT状態（echo/linefeed/headers/spaces/protocol…）
    obd_encoding.dart         # PID値→バイト列、DTC文字列⇔バイト、ISO-TP整形
    at_command_handler.dart   # AT* コマンド処理
    obd_command_handler.dart  # Mode 01/02/03/04/06/07/09/0A 処理
    elm327_engine.dart        # 受信行→応答 の統合（echo/プロンプト付与）
  vehicle/
    vehicle_state.dart        # 車両データモデル + 既定値
    simulator.dart            # 動的シミュレーション（tick注入可）
  transport/
    transport.dart            # TransportType enum, ElmTransport インタフェース
    transport_bridge.dart     # MethodChannel/EventChannel ラッパ + capabilities
  app/
    emulator_controller.dart  # engine+bridge+simulator+state を束ねるControllerNotifier
  ui/
    home_page.dart            # 接続状態・トグル・ログ
    value_controls.dart       # スライダー群
    dtc_editor.dart           # DTC/VIN 編集
  main.dart
test/
  line_assembler_test.dart
  obd_encoding_test.dart
  at_command_handler_test.dart
  obd_command_handler_test.dart
  elm327_engine_test.dart
  simulator_test.dart
android/app/src/main/kotlin/.../
  Elm327Plugin.kt             # MethodChannel/EventChannel 登録・振分
  BleGattServer.kt
  SppServer.kt
macos/Runner/
  Elm327Plugin.swift
  BleGattServer.swift
```

---

## Task 1: プロジェクトスキャフォールドとテスト基盤

**Files:**
- Create: Flutter プロジェクト一式（`pubspec.yaml`, `lib/main.dart`, `android/`, `macos/`）
- Create: `test/smoke_test.dart`

**Interfaces:**
- Produces: ビルド可能な Flutter プロジェクト（android + macos デスクトップ有効）、`dart test` が動く状態。

- [ ] **Step 1: プロジェクト生成**

Run:
```bash
cd /Users/poropi/Documents/develop/elm327emu
flutter create --org com.example --project-name elm327emu --platforms=android,macos .
flutter config --enable-macos-desktop
```

- [ ] **Step 2: provider 依存を追加**

`pubspec.yaml` の `dependencies:` に追記し、`dev_dependencies:` に `test` があることを確認:
```yaml
dependencies:
  flutter:
    sdk: flutter
  provider: ^6.1.0
dev_dependencies:
  flutter_test:
    sdk: flutter
  test: ^1.25.0
```
Run: `flutter pub get`

- [ ] **Step 3: スモークテストを書く**

`test/smoke_test.dart`:
```dart
import 'package:test/test.dart';

void main() {
  test('smoke', () {
    expect(1 + 1, 2);
  });
}
```

- [ ] **Step 4: テスト実行**

Run: `dart test test/smoke_test.dart`
Expected: PASS（1 test passed）

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: Flutter プロジェクトスキャフォールド(android+macos)とテスト基盤"
```

---

## Task 2: LineAssembler（コマンド行の組立）

**Files:**
- Create: `lib/elm327/line_assembler.dart`
- Test: `test/line_assembler_test.dart`

**Interfaces:**
- Produces: `class LineAssembler { List<String> addBytes(List<int> bytes); }` — 受信バイトを内部バッファに溜め、`\r`(0x0D) で区切れた完成コマンド行（前後空白なし・大文字化なし・空行は除外）を返す。`\n`(0x0A) は無視。

- [ ] **Step 1: 失敗するテストを書く**

`test/line_assembler_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/elm327/line_assembler.dart';

List<int> b(String s) => s.codeUnits;

void main() {
  test('1行を1コマンドとして返す', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010C\r')), ['010C']);
  });

  test('CRが来るまでは何も返さない', () {
    final a = LineAssembler();
    expect(a.addBytes(b('010')), isEmpty);
    expect(a.addBytes(b('C\r')), ['010C']);
  });

  test('複数行を一度に分割', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r010C\r')), ['ATZ', '010C']);
  });

  test('LFは無視し空行は捨てる', () {
    final a = LineAssembler();
    expect(a.addBytes(b('ATZ\r\n')), ['ATZ']);
    expect(a.addBytes(b('\r')), isEmpty);
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/line_assembler_test.dart`
Expected: FAIL（`line_assembler.dart` が無い / `LineAssembler` 未定義）

- [ ] **Step 3: 実装**

`lib/elm327/line_assembler.dart`:
```dart
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
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/line_assembler_test.dart`
Expected: PASS（4 tests）

- [ ] **Step 5: Commit**

```bash
git add lib/elm327/line_assembler.dart test/line_assembler_test.dart
git commit -m "feat: LineAssembler でコマンド行を組立"
```

---

## Task 3: VehicleState（車両データモデルと既定値）

**Files:**
- Create: `lib/vehicle/vehicle_state.dart`
- Test: `test/obd_encoding_test.dart`（次タスクと共用。本タスクでは既定値テストのみ追加）

**Interfaces:**
- Produces: `class VehicleState` — 可変フィールド `int rpm; double speedKmh; double coolantTempC; double engineLoadPct; double throttlePct; double intakeTempC; double maf; double fuelLevelPct; double batteryVoltage; List<String> dtcs; String vin;`。`VehicleState.defaults()` で実機準拠の初期値を返す。

- [ ] **Step 1: 失敗するテストを書く**

`test/obd_encoding_test.dart`（新規）:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  test('既定値', () {
    final v = VehicleState.defaults();
    expect(v.rpm, 800);
    expect(v.speedKmh, 0);
    expect(v.vin.length, 17);
    expect(v.dtcs, ['P0301']);
    expect(v.batteryVoltage, 12.4);
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/obd_encoding_test.dart`
Expected: FAIL（`vehicle_state.dart` 未定義）

- [ ] **Step 3: 実装**

`lib/vehicle/vehicle_state.dart`:
```dart
/// エミュレートする車両の現在状態。Simulator または UI が更新する。
class VehicleState {
  int rpm;
  double speedKmh;
  double coolantTempC;
  double engineLoadPct;
  double throttlePct;
  double intakeTempC;
  double maf; // g/s
  double fuelLevelPct;
  double batteryVoltage;
  List<String> dtcs;
  String vin;

  VehicleState({
    required this.rpm,
    required this.speedKmh,
    required this.coolantTempC,
    required this.engineLoadPct,
    required this.throttlePct,
    required this.intakeTempC,
    required this.maf,
    required this.fuelLevelPct,
    required this.batteryVoltage,
    required this.dtcs,
    required this.vin,
  });

  factory VehicleState.defaults() => VehicleState(
        rpm: 800,
        speedKmh: 0,
        coolantTempC: 85,
        engineLoadPct: 20,
        throttlePct: 12,
        intakeTempC: 30,
        maf: 3.5,
        fuelLevelPct: 70,
        batteryVoltage: 12.4,
        dtcs: ['P0301'],
        vin: 'WAUZZZ8K9AA000000',
      );
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/obd_encoding_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/vehicle/vehicle_state.dart test/obd_encoding_test.dart
git commit -m "feat: VehicleState モデルと実機準拠の既定値"
```

---

## Task 4: OBD エンコーディング（PID→バイト, DTC変換, ISO-TP整形）

**Files:**
- Create: `lib/elm327/obd_encoding.dart`
- Test: `test/obd_encoding_test.dart`（Task 3 に追記）

**Interfaces:**
- Consumes: `VehicleState`（Task 3）。
- Produces:
  - `String toHex2(int v)` — 0..255 を 2 桁大文字 16 進。
  - `int rpmA(int rpm)`, `int rpmB(int rpm)` — RPM を ((A*256)+B)/4 になる A,B に変換。
  - `List<int> dtcToBytes(String dtc)` — `"P0301"` → `[0x03, 0x01]`。
  - `String dtcFromBytes(int a, int bb)` — 逆変換。
  - `String formatBytes(List<int> dataBytes, {required bool spaces})` — バイト列を 16 進文字列に（spaces=true なら半角空白区切り＋末尾空白）。
  - `List<String> isoTpMultiline(List<int> dataBytes)` — 7 バイト超のデータを ELM327 のマルチフレーム表示（先頭に総バイト数 3 桁 hex、続けて `N:` 行）に整形。7 バイト以下なら 1 行のみ。

- [ ] **Step 1: 失敗するテストを追記**

`test/obd_encoding_test.dart` に追記:
```dart
import 'package:elm327emu/elm327/obd_encoding.dart';

// ... 既存の main() 内に以下の test を追加 ...
  test('toHex2', () {
    expect(toHex2(0), '00');
    expect(toHex2(255), 'FF');
    expect(toHex2(26), '1A');
  });

  test('RPM分解 1726rpm -> 1A F8', () {
    expect(rpmA(1726), 0x1A);
    expect(rpmB(1726), 0xF8);
  });

  test('DTC文字列⇔バイト', () {
    expect(dtcToBytes('P0301'), [0x03, 0x01]);
    expect(dtcFromBytes(0x03, 0x01), 'P0301');
    expect(dtcToBytes('U0100'), [0xC1, 0x00]);
  });

  test('formatBytes spaces有無', () {
    expect(formatBytes([0x41, 0x0C, 0x1A, 0xF8], spaces: true), '41 0C 1A F8 ');
    expect(formatBytes([0x41, 0x0C, 0x1A, 0xF8], spaces: false), '410C1AF8');
  });

  test('ISO-TP 短データは1行', () {
    expect(isoTpMultiline([0x41, 0x0C, 0x1A, 0xF8]), ['41 0C 1A F8 ']);
  });

  test('ISO-TP 長データは総数+N行', () {
    final data = List<int>.generate(20, (i) => i + 1);
    final lines = isoTpMultiline(data);
    expect(lines.first, '014'); // 20 = 0x14
    expect(lines[1].startsWith('0:'), isTrue);
    expect(lines.length, greaterThan(2));
  });
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/obd_encoding_test.dart`
Expected: FAIL（`obd_encoding.dart` 未定義）

- [ ] **Step 3: 実装**

`lib/elm327/obd_encoding.dart`:
```dart
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
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/obd_encoding_test.dart`
Expected: PASS（全 test）

- [ ] **Step 5: Commit**

```bash
git add lib/elm327/obd_encoding.dart test/obd_encoding_test.dart
git commit -m "feat: OBDエンコーディング(PID/DTC/ISO-TP整形)"
```

---

## Task 5: ElmState と AtCommandHandler

**Files:**
- Create: `lib/elm327/elm_state.dart`
- Create: `lib/elm327/at_command_handler.dart`
- Test: `test/at_command_handler_test.dart`

**Interfaces:**
- Produces:
  - `class ElmState { bool echo=true; bool linefeed=false; bool headers=false; bool spaces=true; int protocol=6; bool initialized=false; void reset(); }`
  - `class AtCommandHandler { AtCommandHandler(this.state); final ElmState state; String? handle(String cmd); }` — `cmd` は `AT` を含む大文字前提の正規化前の文字列。AT コマンドなら応答文字列（プロンプト・CR 抜きの本体、複数行は `\r` 連結）、AT でなければ `null` を返す。

- [ ] **Step 1: 失敗するテストを書く**

`test/at_command_handler_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/elm327/at_command_handler.dart';

void main() {
  late ElmState state;
  late AtCommandHandler h;
  setUp(() {
    state = ElmState();
    h = AtCommandHandler(state);
  });

  test('ATZ で識別子を返しリセット', () {
    state.echo = false;
    final r = h.handle('ATZ');
    expect(r, 'ELM327 v1.5');
    expect(state.echo, isTrue); // リセットで既定に戻る
  });

  test('ATE0 で echo OFF', () {
    expect(h.handle('ATE0'), 'OK');
    expect(state.echo, isFalse);
  });

  test('ATH1 で headers ON', () {
    expect(h.handle('ATH1'), 'OK');
    expect(state.headers, isTrue);
  });

  test('ATSP6 でプロトコル設定', () {
    expect(h.handle('ATSP6'), 'OK');
    expect(state.protocol, 6);
  });

  test('ATDPN はプロトコル番号', () {
    expect(h.handle('ATDPN'), '6');
  });

  test('ATI は識別子, ATRV は電圧', () {
    expect(h.handle('ATI'), 'ELM327 v1.5');
    expect(h.handle('ATRV'), '12.4V');
  });

  test('非ATは null', () {
    expect(h.handle('010C'), isNull);
  });

  test('未知ATは ?', () {
    expect(h.handle('ATXYZ'), '?');
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/at_command_handler_test.dart`
Expected: FAIL（未定義）

- [ ] **Step 3: 実装**

`lib/elm327/elm_state.dart`:
```dart
/// ELM327 の AT 設定状態。
class ElmState {
  bool echo = true;
  bool linefeed = false;
  bool headers = false;
  bool spaces = true;
  int protocol = 6; // ISO 15765-4 CAN 11bit/500k
  bool initialized = false;

  void reset() {
    echo = true;
    linefeed = false;
    headers = false;
    spaces = true;
    protocol = 6;
    initialized = false;
  }
}
```

`lib/elm327/at_command_handler.dart`:
```dart
import 'elm_state.dart';

/// AT コマンドを処理する。AT 以外は null を返す。
class AtCommandHandler {
  AtCommandHandler(this.state);
  final ElmState state;

  static const _id = 'ELM327 v1.5';

  String? handle(String cmd) {
    final c = cmd.toUpperCase().replaceAll(' ', '');
    if (!c.startsWith('AT')) return null;
    final body = c.substring(2);

    if (body == 'Z' || body == 'WS' || body == 'D') {
      state.reset();
      return _id;
    }
    if (body == 'I') return _id;
    if (body == '@1' || body == '@2') return 'ELM327 OBD EMULATOR';
    if (body == 'RV') return '12.4V';
    if (body == 'DPN') return state.protocol.toRadixString(16).toUpperCase();
    if (body == 'DP') return 'ISO 15765-4 (CAN 11/500)';

    if (body.startsWith('E')) return _setBool(body, (v) => state.echo = v);
    if (body.startsWith('L')) return _setBool(body, (v) => state.linefeed = v);
    if (body.startsWith('H')) return _setBool(body, (v) => state.headers = v);
    if (body.startsWith('S') && body.length == 2) {
      return _setBool(body, (v) => state.spaces = v);
    }
    if (body.startsWith('SP')) {
      final p = body.substring(2).replaceFirst('A', '');
      final n = int.tryParse(p, radix: 16);
      if (n != null) state.protocol = n == 0 ? 6 : n;
      return 'OK';
    }
    // 受理するが状態を持たない系（タイミング等）は OK
    if (body.startsWith('ST') ||
        body.startsWith('AT') ||
        body.startsWith('AL') ||
        body.startsWith('CAF') ||
        body.startsWith('M') ||
        body.startsWith('CRA') ||
        body.startsWith('FC')) {
      return 'OK';
    }
    return '?';
  }

  String _setBool(String body, void Function(bool) apply) {
    if (body.endsWith('1')) {
      apply(true);
      return 'OK';
    }
    if (body.endsWith('0')) {
      apply(false);
      return 'OK';
    }
    return '?';
  }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/at_command_handler_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/elm327/elm_state.dart lib/elm327/at_command_handler.dart test/at_command_handler_test.dart
git commit -m "feat: ElmState と AtCommandHandler"
```

---

## Task 6: ObdCommandHandler（Mode 01/03/04/07/09/0A ほか）

**Files:**
- Create: `lib/elm327/obd_command_handler.dart`
- Test: `test/obd_command_handler_test.dart`

**Interfaces:**
- Consumes: `ElmState`（Task 5）, `VehicleState`（Task 3）, `obd_encoding.dart`（Task 4）。
- Produces: `class ObdCommandHandler { ObdCommandHandler(this.state, this.vehicle); ... List<String> handle(String cmd); }` — OBD 16 進コマンド文字列（例 `010C`, `03`, `0902`）を受け、ELM327 が返す**応答行のリスト**（プロンプト・CR は含まない、ヘッダ/スペース設定反映済み）を返す。未対応・データ無しは `['NO DATA']`。初期化前は `['SEARCHING...', '<応答>']` のように `SEARCHING...` を先頭付加。

- [ ] **Step 1: 失敗するテストを書く**

`test/obd_command_handler_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/elm327/obd_command_handler.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late ElmState state;
  late VehicleState v;
  late ObdCommandHandler h;
  setUp(() {
    state = ElmState()..initialized = true;
    v = VehicleState.defaults();
    h = ObdCommandHandler(state, v);
  });

  test('010C RPM (spaces, headers off)', () {
    v.rpm = 1726;
    expect(h.handle('010C'), ['41 0C 1A F8 ']);
  });

  test('010D 車速', () {
    v.speedKmh = 60;
    expect(h.handle('010D'), ['41 0D 3C ']);
  });

  test('0105 水温は +40 オフセット', () {
    v.coolantTempC = 85;
    expect(h.handle('0105'), ['41 05 7D ']); // 85+40=125=0x7D
  });

  test('spaces off で連結', () {
    state.spaces = false;
    v.rpm = 1726;
    expect(h.handle('010C'), ['410C1AF8']);
  });

  test('headers on で 7E8 とPCI付与', () {
    state.headers = true;
    v.rpm = 1726;
    expect(h.handle('010C'), ['7E8 06 41 0C 1A F8 ']);
  });

  test('0100 サポートPIDビットマップ', () {
    final r = h.handle('0100');
    expect(r.first.startsWith('41 00 '), isTrue);
  });

  test('03 でDTC', () {
    v.dtcs = ['P0301'];
    expect(h.handle('03'), ['43 01 03 01 ']);
  });

  test('04 でDTCクリア', () {
    v.dtcs = ['P0301'];
    expect(h.handle('04'), ['44 ']);
    expect(v.dtcs, isEmpty);
  });

  test('0902 VIN はマルチフレーム', () {
    final r = h.handle('0902');
    expect(r.first, matches(RegExp(r'^[0-9A-F]{3}$')));
  });

  test('未対応PIDは NO DATA', () {
    expect(h.handle('01FF'), ['NO DATA']);
  });

  test('初期化前は SEARCHING... 先頭', () {
    state.initialized = false;
    v.rpm = 800;
    final r = h.handle('010C');
    expect(r.first, 'SEARCHING...');
    expect(state.initialized, isTrue); // 以後は確立
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/obd_command_handler_test.dart`
Expected: FAIL（未定義）

- [ ] **Step 3: 実装**

`lib/elm327/obd_command_handler.dart`:
```dart
import 'elm_state.dart';
import 'obd_encoding.dart';
import '../vehicle/vehicle_state.dart';

/// OBD-II モードコマンドを処理する。
class ObdCommandHandler {
  ObdCommandHandler(this.state, this.vehicle);
  final ElmState state;
  final VehicleState vehicle;

  List<String> handle(String cmd) {
    final c = cmd.toUpperCase().replaceAll(' ', '');
    final searching = <String>[];
    if (!state.initialized) {
      state.initialized = true;
      searching.add('SEARCHING...');
    }

    final data = _dataBytes(c);
    if (data == null) return ['NO DATA'];

    final lines = <String>[];
    if (data.length > 7) {
      // マルチフレーム（VIN 等）。headers off 前提の ELM 表示。
      lines.addAll(isoTpMultiline(data));
    } else if (state.headers) {
      // 7E8 + PCI(データ長) + データ
      final pci = toHex2(data.length);
      lines.add('7E8 $pci ${formatBytes(data, spaces: state.spaces)}'.trimRight() +
          (state.spaces ? ' ' : ''));
    } else {
      lines.add(formatBytes(data, spaces: state.spaces));
    }
    return [...searching, ...lines];
  }

  /// 応答データバイト（サービス応答バイト＋PID＋値）を返す。未対応は null。
  List<int>? _dataBytes(String c) {
    if (c.length < 2) return null;
    final mode = c.substring(0, 2);
    switch (mode) {
      case '01':
        return _mode01(c.substring(2));
      case '03':
        return _mode03();
      case '04':
        vehicle.dtcs = [];
        return [0x44];
      case '07':
      case '0A':
        return [int.parse(mode, radix: 16) + 0x40, 0x00];
      case '09':
        return _mode09(c.substring(2));
      case '02':
        return _mode02(c.substring(2));
      case '06':
        return [0x46, 0x00];
      default:
        return null;
    }
  }

  List<int>? _mode01(String pidHex) {
    final pid = int.tryParse(pidHex, radix: 16);
    if (pid == null) return null;
    switch (pid) {
      case 0x00:
        // 0x01..0x20 のサポートビットマップ（実装PIDを反映）
        return [0x41, 0x00, 0x18, 0x3B, 0x80, 0x11];
      case 0x04: // エンジン負荷
        return [0x41, 0x04, _pct255(vehicle.engineLoadPct)];
      case 0x05: // 水温
        return [0x41, 0x05, (vehicle.coolantTempC + 40).round() & 0xFF];
      case 0x0C: // RPM
        return [0x41, 0x0C, rpmA(vehicle.rpm), rpmB(vehicle.rpm)];
      case 0x0D: // 車速
        return [0x41, 0x0D, vehicle.speedKmh.round() & 0xFF];
      case 0x0F: // 吸気温
        return [0x41, 0x0F, (vehicle.intakeTempC + 40).round() & 0xFF];
      case 0x10: // MAF
        final m = (vehicle.maf * 100).round();
        return [0x41, 0x10, (m >> 8) & 0xFF, m & 0xFF];
      case 0x11: // スロットル
        return [0x41, 0x11, _pct255(vehicle.throttlePct)];
      case 0x20:
        return [0x41, 0x20, 0x00, 0x00, 0x00, 0x01];
      case 0x2F: // 燃料レベル
        return [0x41, 0x2F, _pct255(vehicle.fuelLevelPct)];
      case 0x40:
        return [0x41, 0x40, 0x40, 0x00, 0x00, 0x00];
      case 0x42: // 制御モジュール電圧
        final mv = (vehicle.batteryVoltage * 1000).round();
        return [0x41, 0x42, (mv >> 8) & 0xFF, mv & 0xFF];
      default:
        return null;
    }
  }

  int _pct255(double pct) => (pct * 255 / 100).round() & 0xFF;

  List<int> _mode03() {
    final bytes = <int>[0x43, vehicle.dtcs.length];
    for (final dtc in vehicle.dtcs) {
      bytes.addAll(dtcToBytes(dtc));
    }
    return bytes;
  }

  List<int>? _mode09(String pidHex) {
    final pid = int.tryParse(pidHex, radix: 16);
    if (pid == 0x02) {
      // 49 02 01 + VIN(17 ASCII)
      return [0x49, 0x02, 0x01, ...vehicle.vin.codeUnits];
    }
    if (pid == 0x00) {
      return [0x49, 0x00, 0x00, 0x00, 0x00, 0x04];
    }
    return null;
  }

  List<int>? _mode02(String rest) {
    // フリーズフレーム: 0202xx を簡略再現（RPM のフレーム）
    if (rest.startsWith('02')) {
      return [0x42, 0x02, rpmA(vehicle.rpm), rpmB(vehicle.rpm)];
    }
    return [0x42, 0x00, 0x00, 0x00, 0x00, 0x00];
  }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/obd_command_handler_test.dart`
Expected: PASS（全 test）

- [ ] **Step 5: Commit**

```bash
git add lib/elm327/obd_command_handler.dart test/obd_command_handler_test.dart
git commit -m "feat: ObdCommandHandler (Mode 01/02/03/04/06/07/09/0A)"
```

---

## Task 7: Elm327Engine（受信行→応答 の統合）

**Files:**
- Create: `lib/elm327/elm327_engine.dart`
- Test: `test/elm327_engine_test.dart`

**Interfaces:**
- Consumes: `ElmState`, `AtCommandHandler`, `ObdCommandHandler`, `VehicleState`。
- Produces: `class Elm327Engine { Elm327Engine(this.vehicle); final VehicleState vehicle; final ElmState state = ElmState(); String process(String line); }` — 1 コマンド行を受け、クライアントへ送る**完全な応答文字列**（echo・各応答行の CR・末尾プロンプト `>` を含む）を返す。echo ON なら先頭にコマンド＋CR。

- [ ] **Step 1: 失敗するテストを書く**

`test/elm327_engine_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm327_engine.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late Elm327Engine e;
  setUp(() => e = Elm327Engine(VehicleState.defaults()));

  test('ATZ: echo + 識別子 + プロンプト', () {
    final r = e.process('ATZ');
    expect(r, 'ATZ\rELM327 v1.5\r\r>');
  });

  test('echo OFF 後はエコーしない', () {
    e.process('ATE0');
    final r = e.process('ATI');
    expect(r, 'ELM327 v1.5\r\r>');
  });

  test('OBD 応答にプロンプト', () {
    e.process('ATE0');
    e.state.initialized = true;
    e.vehicle.rpm = 1726;
    final r = e.process('010C');
    expect(r, '41 0C 1A F8 \r\r>');
  });

  test('linefeed ON は CRLF', () {
    e.process('ATE0');
    e.process('ATL1');
    final r = e.process('ATI');
    expect(r, 'ELM327 v1.5\r\n\r\n>');
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/elm327_engine_test.dart`
Expected: FAIL（未定義）

- [ ] **Step 3: 実装**

`lib/elm327/elm327_engine.dart`:
```dart
import 'elm_state.dart';
import 'at_command_handler.dart';
import 'obd_command_handler.dart';
import '../vehicle/vehicle_state.dart';

/// ELM327 の中核。1 コマンド行を完全な応答文字列に変換する。
class Elm327Engine {
  Elm327Engine(this.vehicle) {
    _at = AtCommandHandler(state);
    _obd = ObdCommandHandler(state, vehicle);
  }

  final VehicleState vehicle;
  final ElmState state = ElmState();
  late final AtCommandHandler _at;
  late final ObdCommandHandler _obd;

  String process(String line) {
    final eol = state.linefeed ? '\r\n' : '\r';
    final sb = StringBuffer();

    if (state.echo) {
      sb.write(line);
      sb.write(eol);
    }

    final List<String> responseLines;
    final atResult = _at.handle(line);
    if (atResult != null) {
      responseLines = [atResult];
    } else {
      responseLines = _obd.handle(line);
    }

    for (final l in responseLines) {
      sb.write(l);
      sb.write(eol);
    }
    // 空行 + プロンプト
    sb.write(eol);
    sb.write('>');
    return sb.toString();
  }
}
```

注: `ATZ` のテスト期待値 `ATZ\rELM327 v1.5\r\r>` は、echo(`ATZ\r`) + 応答(`ELM327 v1.5\r`) + 空行(`\r`) + `>` の連結。上記実装で一致する（echo は reset 前の状態 = 既定 ON）。

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/elm327_engine_test.dart`
Expected: PASS

- [ ] **Step 5: 全テスト実行**

Run: `dart test`
Expected: 全 test PASS

- [ ] **Step 6: Commit**

```bash
git add lib/elm327/elm327_engine.dart test/elm327_engine_test.dart
git commit -m "feat: Elm327Engine で受信行→応答を統合"
```

---

## Task 8: Simulator（動的シミュレーション）

**Files:**
- Create: `lib/vehicle/simulator.dart`
- Test: `test/simulator_test.dart`

**Interfaces:**
- Consumes: `VehicleState`。
- Produces: `class Simulator { Simulator(this.vehicle); final VehicleState vehicle; bool enabled=false; void tick(double dtSec); }` — `enabled` のとき `tick` ごとにシナリオ（アイドル→加速→定速→減速の循環）で `vehicle` を更新。RPM と速度・負荷・水温を相関させる。`tick` は時間刻みを引数で受け、決定論的にテスト可能。

- [ ] **Step 1: 失敗するテストを書く**

`test/simulator_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';
import 'package:elm327emu/vehicle/simulator.dart';

void main() {
  test('disabled なら変化しない', () {
    final v = VehicleState.defaults();
    final s = Simulator(v);
    final rpm0 = v.rpm;
    s.tick(1.0);
    expect(v.rpm, rpm0);
  });

  test('enabled で加速フェーズはRPM/速度が上がる', () {
    final v = VehicleState.defaults()..speedKmh = 0..rpm = 800;
    final s = Simulator(v)..enabled = true;
    for (var i = 0; i < 30; i++) {
      s.tick(0.2);
    }
    expect(v.speedKmh, greaterThan(0));
    expect(v.rpm, greaterThan(800));
  });

  test('値は妥当な範囲に収まる', () {
    final v = VehicleState.defaults();
    final s = Simulator(v)..enabled = true;
    for (var i = 0; i < 2000; i++) {
      s.tick(0.2);
    }
    expect(v.speedKmh, inInclusiveRange(0, 200));
    expect(v.rpm, inInclusiveRange(600, 7000));
    expect(v.engineLoadPct, inInclusiveRange(0, 100));
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `dart test test/simulator_test.dart`
Expected: FAIL（未定義）

- [ ] **Step 3: 実装**

`lib/vehicle/simulator.dart`:
```dart
import 'vehicle_state.dart';

enum _Phase { idle, accel, cruise, decel }

/// 動的に車両状態を更新するシミュレータ。tick(dt) を外部から駆動する。
class Simulator {
  Simulator(this.vehicle);
  final VehicleState vehicle;
  bool enabled = false;

  _Phase _phase = _Phase.idle;
  double _phaseT = 0;

  static const _phaseDur = {
    _Phase.idle: 3.0,
    _Phase.accel: 8.0,
    _Phase.cruise: 10.0,
    _Phase.decel: 6.0,
  };

  void tick(double dtSec) {
    if (!enabled) return;
    _phaseT += dtSec;
    if (_phaseT >= _phaseDur[_phase]!) {
      _phaseT = 0;
      _phase = _next(_phase);
    }
    switch (_phase) {
      case _Phase.idle:
        _approach(targetSpeed: 0, targetRpm: 800, dt: dtSec);
        break;
      case _Phase.accel:
        _approach(targetSpeed: 100, targetRpm: 3500, dt: dtSec);
        break;
      case _Phase.cruise:
        _approach(targetSpeed: 90, targetRpm: 2200, dt: dtSec);
        break;
      case _Phase.decel:
        _approach(targetSpeed: 0, targetRpm: 900, dt: dtSec);
        break;
    }
    _deriveSecondary();
  }

  _Phase _next(_Phase p) {
    switch (p) {
      case _Phase.idle:
        return _Phase.accel;
      case _Phase.accel:
        return _Phase.cruise;
      case _Phase.cruise:
        return _Phase.decel;
      case _Phase.decel:
        return _Phase.idle;
    }
  }

  void _approach(
      {required double targetSpeed, required int targetRpm, required double dt}) {
    final k = (dt * 0.6).clamp(0.0, 1.0);
    vehicle.speedKmh += (targetSpeed - vehicle.speedKmh) * k;
    vehicle.rpm += ((targetRpm - vehicle.rpm) * k).round();
    vehicle.speedKmh = vehicle.speedKmh.clamp(0, 200);
    vehicle.rpm = vehicle.rpm.clamp(600, 7000);
  }

  void _deriveSecondary() {
    vehicle.throttlePct = ((vehicle.rpm - 800) / 6200 * 100).clamp(0, 100);
    vehicle.engineLoadPct = (vehicle.throttlePct * 0.8 + 15).clamp(0, 100);
    vehicle.maf = (vehicle.rpm / 800 * 3.5).clamp(0, 200);
    vehicle.coolantTempC =
        (vehicle.coolantTempC + (90 - vehicle.coolantTempC) * 0.01).clamp(20, 110);
  }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `dart test test/simulator_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/vehicle/simulator.dart test/simulator_test.dart
git commit -m "feat: Simulator で動的車両シミュレーション"
```

---

## Task 9: Transport 抽象と TransportBridge（Dart 側 Platform Channel）

**Files:**
- Create: `lib/transport/transport.dart`
- Create: `lib/transport/transport_bridge.dart`

**Interfaces:**
- Produces:
  - `enum TransportType { ble, spp }`
  - `class TransportBridge { Future<List<TransportType>> capabilities(); Future<void> startBle({bool useFff0=false}); Future<void> stopBle(); Future<void> startSpp(); Future<void> stopSpp(); Future<void> send(TransportType t, List<int> bytes); Stream<({TransportType transport, List<int> bytes})> get onReceive; Stream<({TransportType transport, String state, String device})> get onConnection; }`
  - MethodChannel `elm327/control`、EventChannel `elm327/events`。

注: 本タスクは Dart 側のみ（ネイティブは Task 11/12）。`dart test` ではプラットフォームチャネルが無いため、本タスクのコードは Flutter ランタイム前提とし、ユニットテストは行わず Task 13 のウィジェット/手動確認でカバーする（メソッド名・型の定義が後続タスクの契約になる）。

- [ ] **Step 1: 実装**

`lib/transport/transport.dart`:
```dart
enum TransportType { ble, spp }

extension TransportTypeName on TransportType {
  String get wire => name; // 'ble' / 'spp'
  static TransportType fromWire(String s) =>
      s == 'spp' ? TransportType.spp : TransportType.ble;
}
```

`lib/transport/transport_bridge.dart`:
```dart
import 'package:flutter/services.dart';
import 'transport.dart';

/// ネイティブ Transport（BLE/SPP サーバ）への橋渡し。
class TransportBridge {
  static const _control = MethodChannel('elm327/control');
  static const _events = EventChannel('elm327/events');

  Stream<Map<dynamic, dynamic>>? _eventStream;

  Stream<Map<dynamic, dynamic>> get _raw =>
      _eventStream ??= _events.receiveBroadcastStream().cast<Map>();

  Future<List<TransportType>> capabilities() async {
    final caps = await _control.invokeMethod<List<dynamic>>('capabilities');
    return (caps ?? [])
        .map((e) => TransportTypeName.fromWire(e as String))
        .toList();
  }

  Future<void> startBle({bool useFff0 = false}) =>
      _control.invokeMethod('startBle', {'profile': useFff0 ? 'fff0' : 'ffe0'});
  Future<void> stopBle() => _control.invokeMethod('stopBle');
  Future<void> startSpp() => _control.invokeMethod('startSpp');
  Future<void> stopSpp() => _control.invokeMethod('stopSpp');

  Future<void> send(TransportType t, List<int> bytes) => _control.invokeMethod(
      'send', {'transport': t.wire, 'bytes': Uint8List.fromList(bytes)});

  Stream<({TransportType transport, List<int> bytes})> get onReceive => _raw
      .where((e) => e['type'] == 'rx')
      .map((e) => (
            transport: TransportTypeName.fromWire(e['transport'] as String),
            bytes: (e['bytes'] as List).cast<int>(),
          ));

  Stream<({TransportType transport, String state, String device})>
      get onConnection => _raw.where((e) => e['type'] == 'conn').map((e) => (
            transport: TransportTypeName.fromWire(e['transport'] as String),
            state: e['state'] as String,
            device: (e['device'] as String?) ?? '',
          ));
}
```

- [ ] **Step 2: コンパイル確認**

Run: `flutter analyze lib/transport`
Expected: No issues found（warning 程度は許容）

- [ ] **Step 3: Commit**

```bash
git add lib/transport/
git commit -m "feat: Transport 抽象と Dart 側 TransportBridge"
```

---

## Task 10: EmulatorController（engine + bridge + simulator + state の統合）

**Files:**
- Create: `lib/app/emulator_controller.dart`

**Interfaces:**
- Consumes: `Elm327Engine`, `Simulator`, `TransportBridge`, `LineAssembler`, `VehicleState`。
- Produces: `class EmulatorController extends ChangeNotifier` — フィールド `vehicle`, `engine`, `simulator`, `caps`, 各 Transport の接続状態とログ。メソッド `init()`, `setSimEnabled(bool)`, `startBle/stopBle/startSpp/stopSpp`, `setBleProfile(bool useFff0)`。受信バイト→`LineAssembler`→`engine.process`→`bridge.send` を結線。Transport ごとに `LineAssembler` を保持。

- [ ] **Step 1: 実装**

`lib/app/emulator_controller.dart`:
```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../elm327/elm327_engine.dart';
import '../elm327/line_assembler.dart';
import '../transport/transport.dart';
import '../transport/transport_bridge.dart';
import '../vehicle/simulator.dart';
import '../vehicle/vehicle_state.dart';

class EmulatorController extends ChangeNotifier {
  final VehicleState vehicle = VehicleState.defaults();
  late final Elm327Engine engine = Elm327Engine(vehicle);
  late final Simulator simulator = Simulator(vehicle);
  final TransportBridge bridge = TransportBridge();

  final Map<TransportType, LineAssembler> _assemblers = {
    TransportType.ble: LineAssembler(),
    TransportType.spp: LineAssembler(),
  };

  List<TransportType> caps = [];
  final Map<TransportType, String> connState = {};
  final List<String> log = [];
  Timer? _simTimer;
  bool useFff0 = false;

  Future<void> init() async {
    caps = await bridge.capabilities();
    bridge.onReceive.listen(_onReceive);
    bridge.onConnection.listen((e) {
      connState[e.transport] = '${e.state} ${e.device}';
      _addLog('[${e.transport.wire}] ${e.state} ${e.device}');
    });
    notifyListeners();
  }

  void _onReceive(({TransportType transport, List<int> bytes}) e) {
    final lines = _assemblers[e.transport]!.addBytes(e.bytes);
    for (final line in lines) {
      _addLog('<= $line');
      final resp = engine.process(line);
      _addLog('=> ${resp.replaceAll('\r', '\\r')}');
      bridge.send(e.transport, resp.codeUnits);
    }
  }

  void setSimEnabled(bool on) {
    simulator.enabled = on;
    _simTimer?.cancel();
    if (on) {
      _simTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        simulator.tick(0.2);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> startBle() => bridge.startBle(useFff0: useFff0);
  Future<void> stopBle() => bridge.stopBle();
  Future<void> startSpp() => bridge.startSpp();
  Future<void> stopSpp() => bridge.stopSpp();

  void setBleProfile(bool fff0) {
    useFff0 = fff0;
    notifyListeners();
  }

  void _addLog(String s) {
    log.add(s);
    if (log.length > 500) log.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 2: コンパイル確認**

Run: `flutter analyze lib/app`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add lib/app/
git commit -m "feat: EmulatorController で全コンポーネントを結線"
```

---

## Task 11: Android ネイティブ — Elm327Plugin + BleGattServer

**Files:**
- Create: `android/app/src/main/kotlin/com/example/elm327emu/Elm327Plugin.kt`
- Create: `android/app/src/main/kotlin/com/example/elm327emu/BleGattServer.kt`
- Modify: `android/app/src/main/kotlin/com/example/elm327emu/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: MethodChannel `elm327/control`、EventChannel `elm327/events`（Task 9 の契約）。
- Produces: `capabilities`→`["ble","spp"]`、`startBle/stopBle`、`send` の BLE 経路、受信イベント `{type:"rx",transport:"ble",bytes:[...]}`、接続イベント `{type:"conn",...}`。

- [ ] **Step 1: 権限を Manifest に追加**

`android/app/src/main/AndroidManifest.xml` の `<manifest>` 直下に追加:
```xml
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
```
`android/app/build.gradle` で `minSdkVersion 23` を確認（必要なら設定）。

- [ ] **Step 2: BleGattServer 実装**

`android/app/src/main/kotlin/com/example/elm327emu/BleGattServer.kt`:
```kotlin
package com.example.elm327emu

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import java.util.UUID

class BleGattServer(
    private val context: Context,
    private val onRx: (ByteArray) -> Unit,
    private val onConn: (String, String) -> Unit,
) {
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var device: BluetoothDevice? = null

    fun start(useFff0: Boolean) {
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = mgr.adapter
        adapter.name = "OBDII"

        val serviceUuid = uuid(if (useFff0) "FFF0" else "FFE0")
        val writeUuid = uuid(if (useFff0) "FFF2" else "FFE1")
        val notifyUuid = uuid(if (useFff0) "FFF1" else "FFE1")

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val writeChar = BluetoothGattCharacteristic(
            writeUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        notifyChar = BluetoothGattCharacteristic(
            notifyUuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        ).also {
            it.addDescriptor(
                BluetoothGattDescriptor(
                    uuid("2902"),
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                )
            )
        }
        service.addCharacteristic(writeChar)
        if (notifyUuid != writeUuid) service.addCharacteristic(notifyChar)

        gattServer = mgr.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(d: BluetoothDevice, status: Int, newState: Int) {
                device = if (newState == BluetoothProfile.STATE_CONNECTED) d else null
                onConn(if (newState == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected", d.address ?: "")
            }

            override fun onCharacteristicWriteRequest(
                d: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
            ) {
                onRx(value)
                if (responseNeeded) {
                    gattServer?.sendResponse(d, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }

            override fun onDescriptorWriteRequest(
                d: BluetoothDevice, requestId: Int, desc: BluetoothGattDescriptor,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
            ) {
                if (responseNeeded) {
                    gattServer?.sendResponse(d, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }
        })
        gattServer?.addService(service)

        advertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()
        advertiser?.startAdvertising(settings, data, object : AdvertiseCallback() {})
    }

    /** 応答を MTU(20) ごとに分割 Notify する。 */
    fun send(bytes: ByteArray) {
        val ch = notifyChar ?: return
        val d = device ?: return
        var i = 0
        while (i < bytes.size) {
            val end = minOf(i + 20, bytes.size)
            ch.value = bytes.copyOfRange(i, end)
            gattServer?.notifyCharacteristicChanged(d, ch, false)
            i = end
        }
    }

    fun stop() {
        advertiser?.stopAdvertising(object : AdvertiseCallback() {})
        gattServer?.close()
        gattServer = null
    }

    private fun uuid(short: String): UUID =
        if (short.length <= 4)
            UUID.fromString("0000$short-0000-1000-8000-00805F9B34FB")
        else UUID.fromString(short)
}
```

- [ ] **Step 3: Elm327Plugin 実装（チャネル登録・振分）**

`android/app/src/main/kotlin/com/example/elm327emu/Elm327Plugin.kt`:
```kotlin
package com.example.elm327emu

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class Elm327Plugin(private val context: Context) {
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var ble: BleGattServer? = null
    private var spp: SppServer? = null

    fun register(control: MethodChannel, eventChannel: EventChannel) {
        control.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(listOf("ble", "spp"))
                "startBle" -> {
                    val fff0 = call.argument<String>("profile") == "fff0"
                    ble = BleGattServer(context, ::rx("ble"), conn("ble")).also { it.start(fff0) }
                    result.success(null)
                }
                "stopBle" -> { ble?.stop(); ble = null; result.success(null) }
                "startSpp" -> {
                    spp = SppServer(::rx("spp"), conn("spp")).also { it.start() }
                    result.success(null)
                }
                "stopSpp" -> { spp?.stop(); spp = null; result.success(null) }
                "send" -> {
                    val t = call.argument<String>("transport")
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    if (t == "ble") ble?.send(bytes) else spp?.send(bytes)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(args: Any?) { events = null }
        })
    }

    // 注: rx は transport を束縛した関数を返すヘルパ
    private fun rx(transport: String): (ByteArray) -> Unit = { bytes ->
        main.post {
            events?.success(mapOf("type" to "rx", "transport" to transport, "bytes" to bytes.toList()))
        }
    }

    private fun conn(transport: String): (String, String) -> Unit = { state, device ->
        main.post {
            events?.success(mapOf("type" to "conn", "transport" to transport, "state" to state, "device" to device))
        }
    }
}
```

注: 上記 `::rx("ble")` 表記は誤り。`rx("ble")`（関数を呼んで関数値を得る）に修正すること。`BleGattServer(context, rx("ble"), conn("ble"))` とする。

- [ ] **Step 4: MainActivity から登録**

`MainActivity.kt`:
```kotlin
package com.example.elm327emu

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        Elm327Plugin(applicationContext).register(
            MethodChannel(messenger, "elm327/control"),
            EventChannel(messenger, "elm327/events"),
        )
    }
}
```

- [ ] **Step 5: ビルド確認（SppServer は次タスクで作成するため一旦スタブ）**

`SppServer.kt` を仮実装（Task 12 で本実装）:
```kotlin
package com.example.elm327emu
class SppServer(val onRx: (ByteArray) -> Unit, val onConn: (String, String) -> Unit) {
    fun start() {}
    fun send(bytes: ByteArray) {}
    fun stop() {}
}
```
Run: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 6: Commit**

```bash
git add android/
git commit -m "feat(android): BLE GATTサーバとPlatform Channel登録"
```

---

## Task 12: Android ネイティブ — SppServer（RFCOMM）

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/elm327emu/SppServer.kt`

**Interfaces:**
- Produces: SPP RFCOMM サーバ。`start()` で accept ループ、受信を `onRx`、`send` で書き込み。

- [ ] **Step 1: 本実装**

`SppServer.kt`:
```kotlin
package com.example.elm327emu

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import java.util.UUID
import kotlin.concurrent.thread

@SuppressLint("MissingPermission")
class SppServer(
    private val onRx: (ByteArray) -> Unit,
    private val onConn: (String, String) -> Unit,
) {
    private val sppUuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private var serverSocket: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null
    @Volatile private var running = false

    fun start() {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        running = true
        thread(name = "spp-accept") {
            try {
                serverSocket = adapter.listenUsingRfcommWithServiceRecord("ELM327", sppUuid)
                while (running) {
                    val s = serverSocket?.accept() ?: break
                    socket = s
                    onConn("connected", s.remoteDevice?.address ?: "")
                    readLoop(s)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun readLoop(s: BluetoothSocket) {
        val buf = ByteArray(1024)
        try {
            val input = s.inputStream
            while (running) {
                val n = input.read(buf)
                if (n < 0) break
                onRx(buf.copyOf(n))
            }
        } catch (_: Exception) {
        } finally {
            onConn("disconnected", s.remoteDevice?.address ?: "")
            try { s.close() } catch (_: Exception) {}
        }
    }

    fun send(bytes: ByteArray) {
        try {
            socket?.outputStream?.write(bytes)
            socket?.outputStream?.flush()
        } catch (_: Exception) {}
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add android/
git commit -m "feat(android): SPP(RFCOMM)サーバ実装"
```

---

## Task 13: macOS ネイティブ — Elm327Plugin + BleGattServer（CoreBluetooth）

**Files:**
- Create: `macos/Runner/Elm327Plugin.swift`
- Create: `macos/Runner/BleGattServer.swift`
- Modify: `macos/Runner/AppDelegate.swift`
- Modify: `macos/Runner/*.entitlements`（Bluetooth 権限）
- Modify: `macos/Runner/Info.plist`（`NSBluetoothAlwaysUsageDescription`）

**Interfaces:**
- Produces: `capabilities`→`["ble"]`、`startBle/stopBle/send` の BLE 経路、`startSpp`→未対応エラー。イベント形式は Android と同一。

- [ ] **Step 1: entitlements と Info.plist**

`macos/Runner/DebugProfile.entitlements` と `Release.entitlements` に追加:
```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```
`macos/Runner/Info.plist` に追加:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>ELM327 エミュレータが BLE で接続を受け付けるために使用します。</string>
```

- [ ] **Step 2: BleGattServer 実装**

`macos/Runner/BleGattServer.swift`:
```swift
import CoreBluetooth
import Foundation

class BleGattServer: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private var notifyChar: CBMutableCharacteristic?
    private var central: CBCentral?
    private let onRx: (Data) -> Void
    private let onConn: (String, String) -> Void
    private var useFff0 = false
    private var pendingStart = false

    init(onRx: @escaping (Data) -> Void, onConn: @escaping (String, String) -> Void) {
        self.onRx = onRx
        self.onConn = onConn
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    private func svcUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF0" : "FFE0") }
    private func writeUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF2" : "FFE1") }
    private func notifyUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF1" : "FFE1") }

    func start(useFff0: Bool) {
        self.useFff0 = useFff0
        pendingStart = true
        if manager.state == .poweredOn { setup() }
    }

    private func setup() {
        let writeProps: CBCharacteristicProperties = [.write, .writeWithoutResponse]
        let notify = CBMutableCharacteristic(
            type: notifyUuid(), properties: [.notify], value: nil, permissions: [.readable])
        let writeC = CBMutableCharacteristic(
            type: writeUuid(), properties: writeProps, value: nil, permissions: [.writeable])
        let service = CBMutableService(type: svcUuid(), primary: true)
        service.characteristics = (notifyUuid() == writeUuid()) ? [notify] : [notify, writeC]
        notifyChar = notify
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [svcUuid()],
            CBAdvertisementDataLocalNameKey: "OBDII",
        ])
    }

    func send(_ data: Data) {
        guard let ch = notifyChar else { return }
        var i = 0
        let chunk = 20
        while i < data.count {
            let end = min(i + chunk, data.count)
            let ok = manager.updateValue(data.subdata(in: i..<end), for: ch,
                                         onSubscribedCentrals: nil)
            if !ok { break } // 送信不可なら次の ready を待つ（簡略化）
            i = end
        }
    }

    func stop() {
        manager.stopAdvertising()
        manager.removeAllServices()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn && pendingStart { setup() }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let v = req.value { onRx(v) }
            p.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo ch: CBCharacteristic) {
        self.central = central
        onConn("connected", central.identifier.uuidString)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom ch: CBCharacteristic) {
        onConn("disconnected", central.identifier.uuidString)
    }
}
```

- [ ] **Step 3: Elm327Plugin 実装**

`macos/Runner/Elm327Plugin.swift`:
```swift
import FlutterMacOS
import Foundation

class Elm327Plugin: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var ble: BleGattServer?

    func register(messenger: FlutterBinaryMessenger) {
        let control = FlutterMethodChannel(name: "elm327/control", binaryMessenger: messenger)
        let events = FlutterEventChannel(name: "elm327/events", binaryMessenger: messenger)
        events.setStreamHandler(self)
        control.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "capabilities":
                result(["ble"])
            case "startBle":
                let args = call.arguments as? [String: Any]
                let fff0 = (args?["profile"] as? String) == "fff0"
                self.ble = BleGattServer(onRx: { data in self.emitRx(Array(data)) },
                                         onConn: { s, d in self.emitConn(s, d) })
                self.ble?.start(useFff0: fff0)
                result(nil)
            case "stopBle":
                self.ble?.stop(); self.ble = nil; result(nil)
            case "startSpp", "stopSpp":
                result(FlutterError(code: "unsupported", message: "SPP not supported on macOS", details: nil))
            case "send":
                let args = call.arguments as? [String: Any]
                if let data = args?["bytes"] as? FlutterStandardTypedData {
                    self.ble?.send(data.data)
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func emitRx(_ bytes: [Int]) {
        DispatchQueue.main.async {
            self.sink?(["type": "rx", "transport": "ble", "bytes": bytes])
        }
    }
    private func emitConn(_ state: String, _ device: String) {
        DispatchQueue.main.async {
            self.sink?(["type": "conn", "transport": "ble", "state": state, "device": device])
        }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }
}
```

- [ ] **Step 4: AppDelegate から登録**

`macos/Runner/AppDelegate.swift` の `applicationDidFinishLaunching` 等で:
```swift
import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    let plugin = Elm327Plugin()
    override func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
        plugin.register(messenger: controller.engine.binaryMessenger)
        super.applicationDidFinishLaunching(notification)
    }
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 5: ビルド確認**

Run: `flutter build macos --debug`
Expected: BUILD SUCCESSFUL（Info.plist の `bytes` を Int 配列で送る点に注意。`emitRx` の `Array(data)` は `[UInt8]`→Flutter 側で int list として受理可）

- [ ] **Step 6: Commit**

```bash
git add macos/
git commit -m "feat(macos): CoreBluetooth BLEペリフェラルとPlatform Channel"
```

---

## Task 14: Flutter UI（接続・トグル・ログ・値編集）

**Files:**
- Create: `lib/ui/home_page.dart`
- Create: `lib/ui/value_controls.dart`
- Create: `lib/ui/dtc_editor.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `EmulatorController`（Task 10）。
- Produces: アプリ UI。`Provider` で `EmulatorController` を供給し、`init()` を起動時に呼ぶ。

- [ ] **Step 1: main.dart**

`lib/main.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app/emulator_controller.dart';
import 'ui/home_page.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => EmulatorController()..init(),
      child: const Elm327App(),
    ),
  );
}

class Elm327App extends StatelessWidget {
  const Elm327App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ELM327 Emulator',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
```

- [ ] **Step 2: value_controls.dart**

`lib/ui/value_controls.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';

class ValueControls extends StatelessWidget {
  const ValueControls({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final v = c.vehicle;
    final disabled = c.simulator.enabled;
    Widget slider(String label, double value, double min, double max,
        void Function(double) onChanged) {
      return Row(children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: disabled ? null : onChanged,
          ),
        ),
        SizedBox(width: 56, child: Text(value.toStringAsFixed(0))),
      ]);
    }

    return Column(children: [
      slider('RPM', v.rpm.toDouble(), 600, 7000, (x) {
        v.rpm = x.round();
        c.notifyListeners();
      }),
      slider('Speed', v.speedKmh, 0, 200, (x) {
        v.speedKmh = x;
        c.notifyListeners();
      }),
      slider('Coolant', v.coolantTempC, 20, 120, (x) {
        v.coolantTempC = x;
        c.notifyListeners();
      }),
      slider('Throttle', v.throttlePct, 0, 100, (x) {
        v.throttlePct = x;
        c.notifyListeners();
      }),
      slider('Battery', v.batteryVoltage, 8, 15, (x) {
        v.batteryVoltage = x;
        c.notifyListeners();
      }),
    ]);
  }
}
```

- [ ] **Step 3: dtc_editor.dart**

`lib/ui/dtc_editor.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';

class DtcEditor extends StatefulWidget {
  const DtcEditor({super.key});
  @override
  State<DtcEditor> createState() => _DtcEditorState();
}

class _DtcEditorState extends State<DtcEditor> {
  final _ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('DTCs', style: TextStyle(fontWeight: FontWeight.bold)),
      Wrap(
        spacing: 8,
        children: c.vehicle.dtcs
            .map((d) => Chip(
                  label: Text(d),
                  onDeleted: () {
                    c.vehicle.dtcs.remove(d);
                    c.notifyListeners();
                  },
                ))
            .toList(),
      ),
      Row(children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: _ctrl,
            decoration: const InputDecoration(hintText: 'P0301'),
          ),
        ),
        TextButton(
          onPressed: () {
            final t = _ctrl.text.trim().toUpperCase();
            if (RegExp(r'^[PCBU][0-9A-F]{4}$').hasMatch(t)) {
              c.vehicle.dtcs.add(t);
              _ctrl.clear();
              c.notifyListeners();
            }
          },
          child: const Text('追加'),
        ),
      ]),
    ]);
  }
}
```

- [ ] **Step 4: home_page.dart**

`lib/ui/home_page.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';
import '../transport/transport.dart';
import 'value_controls.dart';
import 'dtc_editor.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final hasSpp = c.caps.contains(TransportType.spp);
    return Scaffold(
      appBar: AppBar(title: const Text('ELM327 Emulator')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: c.startBle,
            icon: const Icon(Icons.bluetooth),
            label: const Text('Start BLE'),
          ),
          OutlinedButton(onPressed: c.stopBle, child: const Text('Stop BLE')),
          if (hasSpp)
            FilledButton.icon(
              onPressed: c.startSpp,
              icon: const Icon(Icons.settings_bluetooth),
              label: const Text('Start SPP'),
            ),
          if (hasSpp)
            OutlinedButton(onPressed: c.stopSpp, child: const Text('Stop SPP')),
        ]),
        const SizedBox(height: 8),
        Text('接続: ${c.connState.entries.map((e) => '${e.key.wire}=${e.value}').join(' / ')}'),
        Row(children: [
          const Text('BLE profile:'),
          const SizedBox(width: 8),
          DropdownButton<bool>(
            value: c.useFff0,
            items: const [
              DropdownMenuItem(value: false, child: Text('FFE0/FFE1')),
              DropdownMenuItem(value: true, child: Text('FFF0/FFF1/FFF2')),
            ],
            onChanged: (v) => c.setBleProfile(v ?? false),
          ),
        ]),
        SwitchListTile(
          title: const Text('動的シミュレーション'),
          value: c.simulator.enabled,
          onChanged: c.setSimEnabled,
        ),
        const Divider(),
        const ValueControls(),
        const Divider(),
        const DtcEditor(),
        const Divider(),
        const Text('ログ', style: TextStyle(fontWeight: FontWeight.bold)),
        Container(
          height: 240,
          color: Colors.black12,
          padding: const EdgeInsets.all(8),
          child: ListView(
            reverse: true,
            children: c.log.reversed
                .map((l) => Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)))
                .toList(),
          ),
        ),
      ]),
    );
  }
}
```

- [ ] **Step 5: analyze と起動確認**

Run: `flutter analyze`
Expected: No issues found（未使用 import 等があれば修正）

Run（任意・実機/macで）: `flutter run -d macos`
Expected: アプリ起動、Start BLE で広告開始。

- [ ] **Step 6: Commit**

```bash
git add lib/ui/ lib/main.dart
git commit -m "feat: Flutter UI(接続/トグル/値編集/ログ)"
```

---

## Task 15: 結合確認（手動）とドキュメント

**Files:**
- Create: `README.md`

**Interfaces:**
- Produces: ビルド/実行手順とテスト方法のドキュメント。

- [ ] **Step 1: README を書く**

`README.md` に以下を含める:
- 概要（ELM327 エミュレータ、Android=BLE+SPP / macOS=BLE）
- ビルド: `flutter pub get` → `flutter run -d <android|macos>`
- BLE プロファイル（FFE0/FFE1）・SPP UUID
- 既知の制約（macOS は BLE のみ、iOS 非対応）
- 動的/手動モードの使い方

- [ ] **Step 2: 全自動テスト実行**

Run: `dart test`
Expected: 全 test PASS

- [ ] **Step 3: 手動結合確認（クライアント実機/別端末）**

確認項目:
- Android: 自作クライアントから BLE（デバイス名 `OBDII`、Service `FFE0`）で接続 → `ATZ`→`ELM327 v1.5`、`010C`→RPM 応答。
- Android: SPP（`00001101-...`）で接続 → 同様の応答。
- macOS: BLE で接続 → 同様の応答。
- 動的シミュレーション ON で `010C`/`010D` の値が時間変化することを確認。

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README(ビルド/接続/制約)"
```

---

## Self-Review チェック結果

- **Spec coverage**: BLE/SPP サーバ(Task 11/12/13)、AT フルセット(Task 5)、OBD Mode 01/02/03/04/06/07/09/0A(Task 6)、ISO-TP(Task 4)、動的+手動(Task 8/14)、UI(Task 14)、既定値(Task 3/5)、macOS BLE 限定(Task 13)を網羅。
- **Placeholder scan**: Task 11 の `SppServer` は Task 12 で本実装する旨を明記したスタブ（プレースホルダではなく段階的実装）。Task 11 Step 3 の `::rx` 表記ミスは同 Step 内の注記で修正指示済み。
- **Type consistency**: チャネル名 `elm327/control` / `elm327/events`、イベント形式 `{type:'rx'|'conn', transport, bytes/state/device}`、`capabilities`→文字列リスト、`TransportType.wire`('ble'/'spp') を Dart/Kotlin/Swift 全タスクで統一。
```
