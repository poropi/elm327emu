# ELM327 エミュレータ

ELM327 OBD-II アダプタのソフトウェアエミュレータ。自作 OBD クライアントの開発・テスト用。
仮想 CAN バス上の ECU 2 台（エンジン・トランスミッション）、AT コマンド全項目、障害注入を備える。

- **Android**: BLE + Classic SPP の両方に対応
- **macOS**: BLE のみ（Classic SPP 不可）。開発用に TCP でも待ち受けられる
- **iOS**: 非対応

> **未確認**: 実機の Bluetooth（BLE / SPP）での接続と、Torque・Car Scanner などの市販クライアントでの動作は確かめていない。
> 確かめたのは単体テスト（`flutter test`）と、TCP 経由の python-OBD 0.7.3（[tool/python_obd_check](tool/python_obd_check/README.md)）まで。
> 実機での確認手順は末尾の「手動結合確認チェックリスト」にある。

---

## アーキテクチャ

```
クライアント
  │ BLE / SPP（ネイティブ）  または  TCP（開発用・Dart）
  ▼
ElmSession（1 接続に 1 つ）
  ├─ LineAssembler … バイト → コマンド行
  ├─ AtCommands … AT を表で処理 → ElmState を更新
  ├─ （ElmSession 本体）… OBD/UDS 行 → ISO-TP 単一フレーム → バスへ。応答フレームを集めて ISO-TP 復元
  └─ ResponseFormatter … 復元したメッセージ／フレームを ElmState に従って文字列化
  │  CanFrame
  ▼
FaultInjector … 無応答・遅延・欠落・エラー・応答保留・途中欠落
  ▼
VirtualCanBus … フレームを配信。ECU の応答フレームを返す。周期フレームを流す（ATMA 用）
  ├─ Ecu(エンジン 7E0/7E8)
  └─ Ecu(トランスミッション 7E1/7E9)
        └─ ObdServices / UdsServices … VehicleState と EcuProfile を読んで応答を作る
```

Bluetooth サーバはネイティブ側（Kotlin / Swift）で実装し、受信バイト列を Platform Channel（`elm327/control`, `elm327/events`）経由で Dart へ渡す。
Dart 側でプロトコルを解釈・応答を生成し、再びネイティブへ送って送信する。詳細は [設計書](docs/superpowers/specs/2026-09-23-elm327-full-emulation-design.md) を参照。

---

## 対応範囲

- **プロトコル**: CAN のみ（6: 11bit/500k、7: 29bit/500k、8: 11bit/250k、9: 29bit/250k）。自動選択（`ATSP0`）にも対応
- **OBD**: Mode 01（38 PID）/ 02 / 03 / 04 / 06 / 07 / 09 / 0A
- **Mode 22**（DID 読み取り）と否定応答（`7F xx 11` / `7F 22 31` / `7F 22 13`）
- **AT コマンド**: 項目ごとの挙動は [設計書 §5](docs/superpowers/specs/2026-09-23-elm327-full-emulation-design.md#5-at-コマンド) を参照

---

## ビルド / 実行

```bash
flutter pub get

# macOS
flutter run -d macos

# Android (デバイスを接続しておく)
flutter run -d <android-device-id>
```

---

## 接続情報

### BLE (Android / macOS 共通)

| 項目 | 値 |
|------|-----|
| 広告デバイス名 | `OBDII` |
| Primary Service UUID | `FFE0` |
| RX/TX Characteristic | `FFE1` (Write + Notify) |
| 代替 Service UUID | `FFF0` |
| 代替 Characteristic | `FFF1` (Write), `FFF2` (Notify) |

### SPP (Android のみ)

| 項目 | 値 |
|------|-----|
| UUID | `00001101-0000-1000-8000-00805F9B34FB` |

---

## UI

上部の 6 タブで操作する。

| タブ | 内容 |
|---|---|
| 接続 | BLE（開始・停止・切断、プロファイル）、SPP（Android のみ）、TCP（macOS のみ）、ELM の現在状態、最近のやりとり |
| 車両 | 動的 / 手動、イグニッション、基本 6 項目（回転数・車速・水温・スロットル・負荷・電圧）のスライダ、その他の PID |
| DTC | ECU 切替、MIL 状態、確定 / 保留 / 永続 DTC の追加・削除、フリーズフレーム、消去（Mode 04 と同じ処理） |
| ECU | 各 ECU の有効化と ID 表示、Mode 09 情報（VIN など）、Mode 22 DID 表の編集 |
| 障害 | 有効な障害の一覧、イグニッション OFF、切断、ECU 無応答、遅延・欠落、応答保留、途中欠落、エラー応答 |
| ログ | 絞り込み（すべて / ELM 文字列 / CAN フレーム / 障害）、自動スクロール、コピー、クリア（最大 2000 行） |

---

## 開発用 TCP と CLI

UI なしで ELM327 を TCP で待ち受ける（同時 1 接続）。

```bash
dart run bin/elm327_tcp.dart --port 35000 [--transmission] [--dynamic] [--quiet]
```

- `--transmission`: トランスミッション ECU を有効にする
- `--dynamic`: 動的シミュレーションを有効にする
- `--quiet`: 送受信を表示しない

起動すると `listening <port>` を出す。標準入力 1 行が制御コマンド 1 つで、結果は `ok` か `error <理由>`。

```text
ignition on|off / silent <engine|transmission> on|off / delay <ms> / drop <pct>
pending on|off / truncate on|off / error <種類> once|always / error off
transmission on|off / rpm <n> / speed <n> / dtc add <code> / dtc clear / disconnect
```

---

## python-OBD での確認

オープンソースのクライアント python-OBD 0.7.3 で端から端まで確かめる手順は [tool/python_obd_check/README.md](tool/python_obd_check/README.md) を参照。

---

## 既知の制約

- CAN 以外のプロトコル（ISO 9141-2, ISO 14230-4 KWP, SAE J1850, J1939）は再現しない。
- macOS は BLE のみ。Classic Bluetooth SPP はプラットフォーム制限により非対応。
- macOS の切断は疑似的（サービスを登録し直してクライアントを切る）。
- iOS は非対応（BLE ペリフェラルロールの制限）。
- BLE 接続は 1 クライアントのみ同時接続を想定。
- 未確認の前提がある: [設計書 §1「未確認の前提」](docs/superpowers/specs/2026-09-23-elm327-full-emulation-design.md#未確認の前提実装で仮置きし報告で明記する) の 1〜6、[計画「設計書からの変更点」](docs/superpowers/plans/2026-09-23-elm327-full-emulation.md#設計書からの変更点データシート実クライアントで確かめた結果) の 3・8・9。
- Mode 06 の TID・単位 ID は SAE J1979 と照合していない。

---

## テスト

```bash
flutter test
```

（`dart test` ではなく `flutter test` を使う。静的解析は `flutter analyze`）

---

## 手動結合確認チェックリスト

別デバイス / 自作 OBD クライアントを用いて以下を確認する。

- [ ] **(1) Android BLE 接続**
  - クライアントから BLE スキャン → `OBDII` を発見し接続
  - Service `FFE0` / Characteristic `FFE1` を使用
  - `ATZ` 送信 → `ELM327 v1.5` が返る
  - `010C` 送信 → RPM 応答が返る

- [ ] **(2) Android SPP 接続**
  - UUID `00001101-0000-1000-8000-00805F9B34FB` でペアリング・接続
  - `ATZ` → `ELM327 v1.5`、`010C` → RPM 応答を確認

- [ ] **(3) macOS BLE 接続**
  - BLE クライアントから接続 (Android と同じ Service/Characteristic)
  - `ATZ` → `ELM327 v1.5`、`010C` → RPM 応答を確認

- [ ] **(4) 動的シミュレーション確認**
  - UI トグルを Dynamic に切り替え
  - `010C` / `010D` を繰り返し送信し、返却値が時間とともに変化することを確認

- [ ] **(5) 市販クライアント**
  - Torque / Car Scanner で接続し、PID の表示・DTC の読み取りと消去ができる

- [ ] **(6) 切断の検知**
  - 障害タブの「今すぐ切断」でクライアントが切断を検知する（Android BLE / SPP / macOS BLE それぞれ）

- [ ] **(7) イグニッション OFF**
  - 障害タブのイグニッション OFF で、クライアントが「車両と接続できない」と表示する

- [ ] **(8) ECU 2 台**
  - トランスミッションを有効にし、クライアントが ECU 2 台を認識する
