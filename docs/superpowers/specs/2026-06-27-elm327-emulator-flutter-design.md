# ELM327 エミュレータ (Flutter / Android + macOS) 設計書

- 日付: 2026-06-27
- ステータス: 承認済み（実装計画作成へ）

## 1. 目的

Flutter アプリとして ELM327 OBD-II アダプタを「実機同様」にエミュレートする。
自作の OBD クライアントアプリの開発・テストを、実車なしで行えるようにする。

対応プラットフォーム: **Android** と **macOS**。

| 機能 | Android (Kotlin) | macOS (Swift) |
|---|---|---|
| BLE GATT サーバ（ペリフェラル） | ✅ | ✅ |
| Classic SPP (RFCOMM) サーバ | ✅ | ❌（事実上不可） |

→ クライアントは Android エミュレータには BLE / SPP どちらでも、macOS エミュレータには BLE で接続。

## 2. 技術的前提（重要）

Flutter（Dart）単体では Bluetooth の「サーバ / ペリフェラル役」を実装できない:

- BLE の Flutter パッケージはセントラル（クライアント）専用。完全な GATT サーバは無い。
- Classic SPP も Flutter パッケージは全てクライアント側。RFCOMM サーバ待受は無い。

→ Bluetooth 根幹は **プラットフォーム別ネイティブ** を Platform Channel 経由で実装する。
- Android: Kotlin（`BluetoothGattServer`, `BluetoothServerSocket`）
- macOS: Swift（`CBPeripheralManager`）。macOS の Classic SPP サーバは現実的に不可のため BLE のみ。

## 3. スコープ

### 含む
- BLE GATT サーバ + Advertising（Android: Kotlin / macOS: Swift）
- Classic SPP (RFCOMM) サーバ（Android のみ・Kotlin）
- ELM327 コマンドプロトコル（AT + OBD-II モード）フルセット（Dart 共通）
- 動的な車両データシミュレーション + UI からの手動固定切替（Dart 共通）
- Flutter UI（接続状態・送受信ログ・値スライダー・DTC編集・動的/手動トグル、Android/macOS 共通）

### 含まない（YAGNI）
- 実車との実通信
- iOS 対応（Classic SPP 不可・BLE ペリフェラル制約大）
- macOS での Classic SPP
- メーカ固有 PID の網羅・隠しコマンド全て
- クラウド連携・永続ログ（初期版はメモリ内のみ）

## 4. アーキテクチャ

層を「ネイティブ Transport（Kotlin/Swift）」「Dart Protocol」「Dart VehicleData」「Flutter UI」に分離。
ELM327 ロジックは Dart に置き、`dart test` で網羅的にテストする。プラットフォーム差は Transport 層に閉じ込める。

```
Client (自作アプリ)
   │  BLE Write/Notify  または  SPP socket(Androidのみ)
   ▼
[ネイティブ Transport]
   Android(Kotlin): SppServer + BleGattServer
   macOS(Swift):    BleGattServer (CBPeripheralManager)
   │  受信した生バイト → EventChannel → Dart
   ▲  Dart からの応答バイト ← MethodChannel ← Dart
   ▼
[Dart: TransportBridge]  EventChannel受信 / MethodChannel送信のラッパ
   ▼
[Dart: LineAssembler]  '\r' 区切りでコマンド行を組立（Transport別バッファ）
   ▼
[Dart: Elm327Engine]  AT状態保持・コマンド振分・echo/プロンプト付与
   │   ├─ AtCommandHandler
   │   └─ ObdCommandHandler
   ▼
[Dart: VehicleState]  ← Simulator(動的) / UI(手動)
   ▼
応答文字列 → TransportBridge → ネイティブ送信（BLEはMTUに応じ分割Notify）
```

## 5. コンポーネント詳細

### 5.1 ネイティブ Transport（Platform Channel）

共通チャネル設計（Android/macOS で同一 API）:
- MethodChannel `elm327/control`:
  - `capabilities()` — 当該プラットフォームの対応 Transport（android: [ble,spp] / macos: [ble]）
  - `startBle(profile)`, `stopBle()`, `startSpp()`, `stopSpp()`（macOS の spp は未対応エラー）
  - `send(transport, bytes)` — Dart → ネイティブ（クライアントへ送信）
- EventChannel `elm327/events`:
  - 受信バイト `{transport, bytes}`
  - 接続状態変化 `{transport, state, deviceName}`

- **BleGattServer**（共通仕様、実装は各ネイティブ）
  - 既定プロファイル（安価な BLE ELM327 クローン互換）:
    - Service UUID `0000FFE0-0000-1000-8000-00805F9B34FB`
    - Characteristic `0000FFE1-...`（Write Without Response + Notify、両用）
  - 代替プロファイル（設定で切替）: Service `FFF0` / Notify `FFF1` / Write `FFF2`
  - デバイス名 `OBDII` で広告
  - Notify は接続 MTU（既定 20 バイト）に応じて応答を分割送信
  - Android: `BluetoothGattServer` + `BluetoothLeAdvertiser`
  - macOS: `CBPeripheralManager`（`add(service)` / `startAdvertising` / `updateValue` で Notify）
- **SppServer**（Android のみ）
  - `listenUsingRfcommWithServiceRecord("ELM327", SPP_UUID)`
  - SPP_UUID = `00001101-0000-1000-8000-00805F9B34FB`
  - accept ループ → 受信スレッド → EventChannel

両 Transport は同時待受可能（Android）。初期版は同時接続「1 接続まで」を基本（超過は拒否）。

### 5.2 Dart プロトコルエンジン（純 Dart・テスト容易）

- **TransportBridge**: EventChannel 受信を `onReceive(transport, bytes)` に、`send` を MethodChannel に橋渡し。`capabilities()` で UI に対応 Transport を伝える。
- **LineAssembler**: バイト列をバッファし `\r`(0x0D) で 1 コマンド切出し。`\n` は無視。Transport ごとに独立バッファ。
- **Elm327Engine**:
  - AT 状態: echo(E)、linefeed(L)、headers(H)、spaces(S)、選択プロトコル(SP)、adaptive timing(AT)、timeout(ST)。
  - 処理: echo ON ならコマンドをエコー → `AT` 始まりは `AtCommandHandler`、16進は `ObdCommandHandler`
    → 応答末尾に `\r`（linefeed ON なら `\r\n`）→ 最後にプロンプト `>` 付与。
- **AtCommandHandler**（主要セット）:
  - `ATZ`/`ATWS`（→ `ELM327 v1.5`）、`ATE0/E1`、`ATL0/L1`、`ATH0/H1`、`ATS0/S1`、
    `ATSP h`/`ATSPA h`、`ATDP`/`ATDPN`、`ATI`、`AT@1`/`AT@2`、`ATRV`、`ATST hh`、`ATAT n`、
    `ATM0`、`ATCAF0/1` 等。未知 AT は実機挙動に合わせ `OK` か `?`。
- **ObdCommandHandler**（OBD-II モード フルセット）:
  - Mode 01: 現在値（PID 00/20/40 サポートビットマップ、0C RPM、0D 車速、05 水温、04 負荷、
    11 スロットル、0F 吸気温、10 MAF、2F 燃料、42 電圧 ほか）
  - Mode 02: フリーズフレーム
  - Mode 03: 確定 DTC 読取
  - Mode 04: DTC 消去
  - Mode 06: テスト結果（代表値）
  - Mode 07: 保留 DTC
  - Mode 09: 車両情報（0902 VIN ほか）
  - Mode 0A: 永久 DTC
  - ヘッダ(H)/スペース(S) 設定に従いバイト整形。VIN 等の複数フレーム応答は ISO-TP
    （First Frame / Consecutive Frame）形式。

### 5.3 車両データモデル（Dart）

- **VehicleState**: rpm, speedKmh, coolantTempC, engineLoadPct, throttlePct, intakeTempC, maf,
  fuelLevelPct, batteryVoltage, dtcList, vin。
- **Simulator**（動的モード）: Stream/Timer で一定間隔（100–250ms）に状態更新。
  シナリオ「アイドリング → 加速 → 定速 → 減速」を循環し、RPM と車速・負荷・水温を相関させる。
  時間刻みを注入可能にし決定論的テストを可能にする。
- **手動モード**: UI のスライダー/入力で固定。動的/手動はトグル切替。

### 5.4 Flutter UI（Android / macOS 共通）

- 対応 Transport を `capabilities()` から取得し、BLE / SPP の advertising・接続状態を表示
  （macOS では SPP を非表示/無効化）
- 送受信ログ（リアルタイム）
- 動的 / 手動 トグル
- 主要値スライダー（RPM・車速・水温・スロットル・電圧 等）
- DTC リスト編集（追加/削除）・VIN 編集
- BLE プロファイル切替（FFE0 / FFF0）

## 6. エミュレート既定値（実機準拠）

- `ATI` → `ELM327 v1.5`
- `ATRV` → `12.4V`
- 既定プロトコル: ISO 15765-4 CAN 11bit/500kbps（番号 6）。`ATDPN` → `6`。
- Mode 01 PID 00/20/40 のサポートビットマップは実装 PID 群と整合。
- 既定 VIN・既定 DTC（例 P0301）をサンプル用意。

## 7. エラー処理 / エッジケース

- 未知コマンド → `?`、該当データなし/未対応 PID → `NO DATA`
- 初期化前の OBD 要求 → `SEARCHING...` 後に応答 or `UNABLE TO CONNECT` を簡略再現
- 応答には常にプロンプト `>` 付与
- BLE: MTU 超過は分割 Notify、切断時は advertising 再開
- SPP: ソケット切断時は accept ループへ復帰
- macOS で SPP 操作要求 → `capabilities` 外として UI で無効化、ネイティブは未対応エラー

## 8. テスト戦略

- **Dart 単体テスト**（TDD）でプロトコルエンジンを網羅:
  - AT 状態遷移（E/L/H/S/SP）と echo 有無の応答差
  - 各 Mode 01 PID のバイト整形（H/S 設定込み）
  - Mode 03/09 等のマルチフレーム（ISO-TP）整形
  - LineAssembler の `\r` 分割・分割受信の結合（Transport 別バッファ）
  - 未知コマンド・NO DATA のエッジケース
  - Simulator の決定論的更新（時間刻み注入）
- **結合テスト**: 実機/実マシン（エミュレータ + クライアント）で BLE（Android/macOS）と SPP（Android）を確認。
- ネイティブ Transport は手動結合確認が中心。

## 9. 前提・確認事項

- Android: エミュレータ端末は **BLE Advertising 対応**。Android 12+ は BLUETOOTH_ADVERTISE /
  BLUETOOTH_CONNECT 権限が必要。minSdk 23+ 想定（実装計画で確定）。
- macOS: CoreBluetooth ペリフェラル使用。Info.plist の Bluetooth 用途文言と
  App Sandbox の Bluetooth 権限が必要。
- 開発は macOS 上で Flutter + android-cli を用いてスキャフォールド/ビルド/デプロイ。
- Platform Channel のバイト転送は EventChannel(受信)/MethodChannel(送信)。レイテンシは許容範囲。
```
