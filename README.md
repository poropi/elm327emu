# ELM327 エミュレータ

ELM327 OBD-II アダプタのソフトウェアエミュレータ。自作 OBD クライアントの開発・テスト用。

- **Android**: BLE + Classic SPP の両方に対応
- **Windows**: BLE + Classic SPP の両方に対応（C++/WinRT、要 Windows 機でのビルド/検証）
- **macOS**: BLE のみ（Classic SPP 不可）
- **iOS**: 非対応

---

## アーキテクチャ

```
Flutter (Dart)
├── ELM327 プロトコルエンジン  (lib/elm327/)
├── OBD シミュレータ            (lib/simulator/)
└── UI                          (lib/ui/)

Platform Channel (elm327/control, elm327/events)
├── Android (Kotlin)     ── BLE GATT サーバ + Classic SPP サーバ
├── Windows (C++/WinRT)  ── BLE GATT サーバ + Classic SPP サーバ
└── macOS   (Swift)      ── BLE GATT サーバのみ
```

Bluetooth サーバはネイティブ側(Kotlin/Swift)で実装し、受信バイト列を Platform Channel 経由で Dart へ渡す。Dart 側でプロトコルを解釈・応答を生成し、再びネイティブへ送って送信する。

---

## ビルド / 実行

```bash
flutter pub get

# macOS
flutter run -d macos

# Android (デバイスを接続しておく)
flutter run -d <android-device-id>

# Windows (要 Windows 10 1703+ / Visual Studio + "Desktop development with C++")
flutter config --enable-windows-desktop
flutter run -d windows
```

> **Windows のビルドについて**: Windows ネイティブ Transport は C++/WinRT で実装されており、
> ビルド・動作確認は **Windows 機でのみ** 可能（macOS/Linux ではコンパイル不可）。
> 初回ビルド時に WinRT API の型・async まわりで微修正が必要になる場合がある。

---

## 接続情報

### BLE (Android / Windows / macOS 共通)

| 項目 | 値 |
|------|-----|
| 広告デバイス名 | `OBDII` |
| Primary Service UUID | `FFE0` |
| RX/TX Characteristic | `FFE1` (Write + Notify) |
| 代替 Service UUID | `FFF0` |
| 代替 Characteristic | `FFF1` (Write), `FFF2` (Notify) |

### SPP (Android / Windows)

| 項目 | 値 |
|------|-----|
| UUID | `00001101-0000-1000-8000-00805F9B34FB` |

### 既定レスポンス

| コマンド | 応答 |
|---------|------|
| `ATI` / `ATZ` | `ELM327 v1.5` |
| `0100` | サポート PID ビットマップ |
| `010C` | エンジン回転数 (RPM) |
| `010D` | 車速 (km/h) |

プロトコル: ISO 15765-4 CAN 11bit/500k

---

## UI の使い方

### 動的シミュレーションモード (Dynamic)

画面上部のトグルを **Dynamic** にすると、RPM・車速などのセンサ値が時間とともに自動変化する。スライダで変化の速さ・範囲を調整できる。

### 手動モード (Manual)

トグルを **Manual** にすると、スライダで各センサ値を固定値に設定できる。

### DTC 編集

DTC パネルに `P0301` などのコードを入力して「追加」を押すと、Mode 03 の応答に反映される。チップの × で削除。

### VIN 編集

VIN フィールドを直接編集すると、Mode 09 PID 02 の応答に反映される。

---

## 既知の制約

- macOS は BLE のみ。Classic Bluetooth SPP はプラットフォーム制限により非対応。
- iOS は非対応（BLE ペリフェラルロールの制限）。
- BLE 接続は 1 クライアントのみ同時接続を想定。
- Windows は BLE+SPP 対応だが、WinRT の BLE ペリフェラル/RFCOMM サーバは環境依存の挙動がある。
  特に広告デバイス名はアダプタ名に依存することがあり、`OBDII` がそのまま広告名に出ない場合がある。
  非パッケージ(Win32)実行での `GattServiceProvider` / `RfcommServiceProvider` の可否を最初に確認すること。

---

## テスト

プロトコルエンジン・シミュレータの単体テストを実行:

```bash
dart test
```

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

- [ ] **(4) Windows BLE 接続**（Windows 機でビルド後）
  - BLE クライアントから接続（Android/macOS と同じ Service `FFE0` / Characteristic `FFE1`）
  - `ATZ` → `ELM327 v1.5`、`010C` → RPM 応答を確認

- [ ] **(5) Windows SPP 接続**（Windows 機でビルド後）
  - UUID `00001101-0000-1000-8000-00805F9B34FB` で接続
  - `ATZ` → `ELM327 v1.5`、`010C` → RPM 応答を確認

- [ ] **(6) 動的シミュレーション確認**
  - UI トグルを Dynamic に切り替え
  - `010C` / `010D` を繰り返し送信し、返却値が時間とともに変化することを確認
