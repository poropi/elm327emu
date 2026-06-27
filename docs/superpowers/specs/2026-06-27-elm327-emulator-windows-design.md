# ELM327 エミュレータ — Windows 対応 設計書（追補）

- 日付: 2026-06-27
- ステータス: レビュー待ち
- 親設計: `2026-06-27-elm327-emulator-flutter-design.md`

## 1. 目的

既存の Flutter ELM327 エミュレータ（Android: BLE+SPP / macOS: BLE）に **Windows** を追加し、
Windows 上でも **BLE と Classic SPP の両方** でクライアントを受け付けられるようにする。

## 2. 実現方式（技術的前提）

Windows は WinRT API でサーバ/ペリフェラル役を両方提供できる:

| 機能 | WinRT API | 名前空間 |
|---|---|---|
| BLE GATT サーバ（ペリフェラル） | `GattServiceProvider` | Windows.Devices.Bluetooth.GenericAttributeProfile |
| Classic SPP (RFCOMM) サーバ | `RfcommServiceProvider` + `StreamSocketListener` | Windows.Devices.Bluetooth.Rfcomm / Networking.Sockets |

→ Windows は **Android と同等（BLE+SPP）**。capabilities は `["ble","spp"]` を返す。

Flutter の Windows ランナーは **C++** なので、ネイティブ実装は **C++/WinRT** で書く。
新規プラグインパッケージは作らず、既存の Android(MainActivity)/macOS(AppDelegate) と同様に
**Windows ランナー内にチャネル登録クラスを実装**する（単一アプリ用途で十分）。

## 3. 対応プラットフォーム（更新後の全体像）

| 機能 | Android (Kotlin) | macOS (Swift) | Windows (C++/WinRT) |
|---|---|---|---|
| BLE GATT サーバ | ✅ | ✅ | ✅ |
| Classic SPP サーバ | ✅ | ❌ | ✅ |

iOS は引き続き非対応。

## 4. アーキテクチャ（既存契約の再利用）

Dart 側（プロトコルエンジン・シミュレータ・UI・TransportBridge）は**変更なし**。
既存の Platform Channel 契約をそのまま実装する:

- MethodChannel `elm327/control`: `capabilities`→`["ble","spp"]`, `startBle({profile})`, `stopBle`,
  `startSpp`, `stopSpp`, `send({transport,bytes})`
- EventChannel `elm327/events`: `{type:'rx',transport,bytes:[int]}`, `{type:'conn',transport,state,device}`
- BLE 既定プロファイル Service `FFE0` / Char `FFE1`（Write+Notify）、代替 `FFF0/FFF1/FFF2`。広告名 `OBDII`。
- SPP UUID `00001101-0000-1000-8000-00805F9B34FB`、サービス名 `ELM327`。

唯一の追加は **Windows ネイティブ Transport 実装**。

## 5. コンポーネント（Windows 追加分）

`windows/runner/` に C++/WinRT で:

- **Elm327Plugin（チャネル登録・振分）**
  - `flutter::MethodChannel<EncodableValue>`("elm327/control") と
    `flutter::EventChannel<EncodableValue>`("elm327/events") を `FlutterEngine` の messenger に登録。
  - `flutter_window.cpp`（または runner 初期化）から生成・登録。
  - 受信バイト/接続状態を **UI スレッド（メッセージループ）にマーシャリング**してから EventSink へ。
    （Flutter のチャネルは生成スレッドからのみ呼べるため、WinRT のコールバックスレッドから直接呼ばない）
- **BleGattServer（C++/WinRT）**
  - `GattServiceProvider::CreateAsync(serviceUuid)` でサービス生成。
  - FFE0: 単一特性 FFE1 を `GattCharacteristicProperties::Write | WriteWithoutResponse | Notify` で作成
    （Android/macOS と同じ単一特性方式）。FFF0: FFF2(write) と FFF1(notify) を分離。
  - `WriteRequested` イベント → 値を onRx、必要なら `Respond`。
  - `SubscribedClientsChanged` → 接続/切断を onConn。
  - 応答は `GattLocalCharacteristic::NotifyValueAsync` で送信（必要に応じ MTU 分割）。
  - `StartAdvertising`（`GattServiceProviderAdvertisingParameters` で IsConnectable/IsDiscoverable=true）。
    ローカル名 `OBDII` の広告（広告名はアダプタ名/別途設定に依存する点を実装計画で確認）。
- **SppServer（C++/WinRT）**
  - `RfcommServiceProvider::CreateAsync(RfcommServiceId::FromUuid(SPP_UUID))`。
  - `StreamSocketListener` を `ConnectionReceived` で待ち受け、`StartAdvertising`。
  - 受信は `DataReader` ループ→onRx、送信は `DataWriter`。切断検知で待受へ復帰。

## 6. ビルド・検証（重要な制約）

- ビルドには **Windows 10 1703+ / Visual Studio（Desktop development with C++）/ Flutter Windows desktop** が必須。
  `flutter config --enable-windows-desktop` と `flutter create --platforms=windows .` で `windows/` を追加。
- **本 macOS 環境では C++/WinRT のコンパイル・動作確認ができない。** コードは規約に従って作成するが、
  コンパイル通過・実機動作確認は **Windows 機で実施**し、必要なら追補修正する（初回は WinRT API の
  型・async 取り扱いでビルド修正が入る前提）。
- リスク: WinRT のBLEペリフェラル（GattServiceProvider）は環境によりカスタム広告名やペリフェラル
  挙動にクセがある。非パッケージ(Win32)アプリでの GattServiceProvider/RfcommServiceProvider 利用可否を
  最初に小さく検証する。

## 7. スコープ

### 含む
- Windows ネイティブ BLE GATT サーバ + Classic SPP サーバ（C++/WinRT）
- `windows/` ランナーへのチャネル登録、capabilities=["ble","spp"]
- Dart 側 UI が Windows でも BLE/SPP 両ボタンを表示（caps 由来で自動）

### 含まない（YAGNI）
- Dart エンジン/プロトコルの変更（不要）
- UWP/appx パッケージ化（まず非パッケージ Win32 で）
- 本 macOS 環境でのビルド/検証（Windows 機で実施）

## 8. テスト戦略

- Dart 側は既存テストで担保済み（変更なし）。
- Windows ネイティブは Windows 機で:
  - ビルド通過（`flutter build windows`）
  - 別デバイス/自作クライアントから BLE 接続 → `ATZ`→`ELM327 v1.5`、`010C`→RPM 応答
  - SPP 接続 → 同様
- 本 PR/作業では「コード作成 + 詳細なビルド/検証手順」を成果物とし、実機検証は Windows 環境で行う。
