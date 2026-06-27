# ELM327 エミュレータ — Windows 対応 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 既存 Flutter ELM327 エミュレータに Windows を追加し、Windows 上で BLE と Classic SPP の両方でクライアントを受け付けられるようにする。

**Architecture:** Dart 側（プロトコルエンジン・シミュレータ・UI・TransportBridge）は無変更。既存の Platform Channel 契約（`elm327/control` MethodChannel + `elm327/events` EventChannel）を満たす Windows ネイティブ Transport を C++/WinRT で `windows/runner` 内に実装する。BLE は `GattServiceProvider`、SPP は `RfcommServiceProvider`。

**Tech Stack:** Flutter Windows desktop（C++ ランナー）、C++/WinRT、WinRT Bluetooth API（GenericAttributeProfile / Rfcomm / Networking.Sockets）。

## Global Constraints

- **このリポジトリは macOS 上にあり、C++/WinRT のビルド・動作確認はできない。** 各タスクの「ビルド」「実行」ステップは **Windows 機（Windows 10 1703+、Visual Studio with Desktop development with C++、Flutter windows desktop 有効）でのみ実行可能**。macOS 上で作業するエージェントは、コード作成・`flutter analyze`（Dart 側のみ）・静的レビューまでを行い、ビルド/実行ステップは「Windows 機で実施」と明記してスキップしてよい（BLOCKED ではなく、環境制約として report に記録）。
- 既存契約を厳守（Dart 側 `lib/transport/transport_bridge.dart` と一致させる）:
  - MethodChannel `elm327/control`: メソッド `capabilities`→`["ble","spp"]`、`startBle`（引数 `{"profile":"ffe0"|"fff0"}`）、`stopBle`、`startSpp`、`stopSpp`、`send`（引数 `{"transport":"ble"|"spp","bytes":<byte list>}`）。
  - EventChannel `elm327/events`: `{"type":"rx","transport":"ble"|"spp","bytes":<List<int>>}` と `{"type":"conn","transport":...,"state":"connected"|"disconnected","device":<String>}`。
- BLE 既定プロファイル: Service `FFE0`(`0000FFE0-0000-1000-8000-00805F9B34FB`) / Characteristic `FFE1`(Write + WriteWithoutResponse + Notify)。代替: Service `FFF0` / Notify `FFF1` / Write `FFF2`。広告名 `OBDII`、connectable。
- SPP: `RfcommServiceId` = `00001101-0000-1000-8000-00805F9B34FB`、サービス名 `ELM327`。
- BLE 応答は接続 MTU（既定 20 バイト相当）で分割 Notify。
- **スレッド制約**: Flutter の MethodChannel/EventChannel は生成スレッド（Windows UI スレッド）からのみ呼べる。WinRT の非同期コールバックは別スレッドで発火するため、`EventSink::Success` や `MethodResult` 応答は **必ず UI スレッドへマーシャリング**してから呼ぶ（後述の `PostToUi` ヘルパ経由）。
- C++/WinRT の async は `.get()`（同期待ち、UI スレッドをブロックしない場所で）または継続で扱う。UI スレッドをブロックしないこと。
- DRY/YAGNI。新規プラグインパッケージは作らない（runner 内実装）。Dart 側は変更しない。

---

## File Structure

```
windows/                              # flutter create --platforms=windows で生成（Task 1）
  runner/
    elm327_plugin.h / .cpp            # MethodChannel/EventChannel 登録・振分・UIスレッドマーシャリング
    ble_gatt_server.h / .cpp          # GattServiceProvider ベースの BLE ペリフェラル
    spp_server.h / .cpp               # RfcommServiceProvider + StreamSocketListener
    flutter_window.cpp                # (修正) プラグイン生成・登録フックを追加
    CMakeLists.txt                    # (修正) 新規 .cpp を追加、C++/WinRT 有効化、cppwinrt 依存
```

Dart 側・Android・macOS は変更しない。

---

## Task 1: Windows ターゲットのスキャフォールドと配線確認（C++/WinRT 有効化）

**Files:**
- Create: `windows/`（`flutter create --platforms=windows .`）
- Modify: `windows/runner/CMakeLists.txt`（C++/WinRT 有効化）

**Interfaces:**
- Produces: `flutter build windows` が（最小構成で）通る Windows ランナー。C++/WinRT が使える状態。

> 注: 本タスク以降のビルド系ステップは Windows 機専用。macOS 作業者は生成ファイルの内容と CMake 設定の妥当性をレビューし、ビルドは「Windows 機で実施」と report に記す。

- [ ] **Step 1: Windows ターゲット生成（Windows 機）**

Run:
```bash
flutter config --enable-windows-desktop
flutter create --org com.example --project-name elm327emu --platforms=windows .
```
Expected: `windows/` 配下に runner（C++）が生成される。既存 `lib/` `android/` `macos/` は保持。

- [ ] **Step 2: C++/WinRT を CMake で有効化**

`windows/runner/CMakeLists.txt` の `apply_standard_settings(${BINARY_NAME})` の後に、WinRT 利用のための設定を追加:
```cmake
# C++/WinRT を有効化（C++17 と cppwinrt ヘッダ）
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_17)
target_link_libraries(${BINARY_NAME} PRIVATE
  "windowsapp"            # WinRT ランタイム
)
```
（Visual Studio 2019/2022 には C++/WinRT ヘッダが同梱。`#include <winrt/...>` で利用可能。別途 cppwinrt NuGet を使う場合は実装計画ではなく Windows 機で調整。）

- [ ] **Step 3: ビルド確認（Windows 機）**

Run: `flutter build windows --debug`
Expected: BUILD SUCCESSFUL（この時点ではまだプラグイン未追加の素の Windows アプリ）。

- [ ] **Step 4: Commit**

```bash
git add windows/
git commit -m "chore(windows): WindowsターゲットをスキャフォールドしC++/WinRTを有効化"
```

---

## Task 2: Elm327Plugin（チャネル登録・振分・UI スレッドマーシャリング）

**Files:**
- Create: `windows/runner/elm327_plugin.h`
- Create: `windows/runner/elm327_plugin.cpp`
- Modify: `windows/runner/flutter_window.cpp`（プラグイン生成・登録）
- Modify: `windows/runner/CMakeLists.txt`（新規 .cpp を追加）

**Interfaces:**
- Consumes: Flutter Windows embedding（`flutter::MethodChannel`, `flutter::EventChannel`, `flutter::EncodableValue`, `flutter::BinaryMessenger`）。
- Produces:
  - `class Elm327Plugin` — `void Register(flutter::BinaryMessenger* messenger, HWND hwnd)`、内部に
    `void EmitRx(const std::string& transport, const std::vector<uint8_t>& bytes)` と
    `void EmitConn(const std::string& transport, const std::string& state, const std::string& device)`、
    `void PostToUi(std::function<void()>)`（UI スレッドへマーシャリング）。
  - `capabilities` → `EncodableList{"ble","spp"}`。
  - 後続タスクの `BleGattServer` / `SppServer` を保持・起動・停止し、`send` を振り分ける。
    （本タスクでは両サーバを **前方宣言＋null ポインタ**として用意し、メソッドは受理して TODO とする。
    Task 3/4 で実体を差し込む。）

- [ ] **Step 1: ヘッダ作成**

`windows/runner/elm327_plugin.h`:
```cpp
#ifndef RUNNER_ELM327_PLUGIN_H_
#define RUNNER_ELM327_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/encodable_value.h>
#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>
#include <functional>
#include <string>
#include <vector>

class BleGattServer;  // Task 3
class SppServer;      // Task 4

// ELM327 用の MethodChannel/EventChannel を登録し、ネイティブ Transport に振り分ける。
class Elm327Plugin {
 public:
  Elm327Plugin();
  ~Elm327Plugin();

  // messenger は engine->messenger()、hwnd は UI スレッド識別用（PostMessage 先）。
  void Register(flutter::BinaryMessenger* messenger, HWND hwnd);

  // ネイティブのコールバックスレッドから呼ばれる。内部で UI スレッドへマーシャリングする。
  void EmitRx(const std::string& transport, const std::vector<uint8_t>& bytes);
  void EmitConn(const std::string& transport, const std::string& state,
                const std::string& device);

 private:
  void PostToUi(std::function<void()> fn);
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> control_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  std::unique_ptr<BleGattServer> ble_;
  std::unique_ptr<SppServer> spp_;

  HWND ui_hwnd_ = nullptr;     // メッセージ受信用の隠しウィンドウ
};

#endif  // RUNNER_ELM327_PLUGIN_H_
```

- [ ] **Step 2: 実装作成**

`windows/runner/elm327_plugin.cpp`:
```cpp
#include "elm327_plugin.h"

#include <flutter/standard_method_codec.h>

#include <queue>
#include <mutex>

namespace {
constexpr wchar_t kUiWndClass[] = L"Elm327PluginUiSink";
constexpr UINT kWmRunTask = WM_USER + 1;

// PostToUi で渡された関数を保持するキュー（hwnd ごとに 1 つの簡易実装）。
std::mutex g_task_mutex;
std::queue<std::function<void()>> g_tasks;
}  // namespace

Elm327Plugin::Elm327Plugin() = default;
Elm327Plugin::~Elm327Plugin() = default;

using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;

LRESULT CALLBACK Elm327Plugin::WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
  if (msg == kWmRunTask) {
    std::function<void()> fn;
    {
      std::lock_guard<std::mutex> lock(g_task_mutex);
      if (!g_tasks.empty()) { fn = std::move(g_tasks.front()); g_tasks.pop(); }
    }
    if (fn) fn();
    return 0;
  }
  return DefWindowProc(hwnd, msg, w, l);
}

void Elm327Plugin::PostToUi(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lock(g_task_mutex);
    g_tasks.push(std::move(fn));
  }
  PostMessage(ui_hwnd_, kWmRunTask, 0, 0);
}

void Elm327Plugin::EmitRx(const std::string& transport,
                          const std::vector<uint8_t>& bytes) {
  EncodableList list;
  for (auto b : bytes) list.push_back(EncodableValue(static_cast<int>(b)));
  PostToUi([this, transport, list]() {
    if (!sink_) return;
    sink_->Success(EncodableValue(EncodableMap{
        {EncodableValue("type"), EncodableValue("rx")},
        {EncodableValue("transport"), EncodableValue(transport)},
        {EncodableValue("bytes"), EncodableValue(list)},
    }));
  });
}

void Elm327Plugin::EmitConn(const std::string& transport,
                            const std::string& state,
                            const std::string& device) {
  PostToUi([this, transport, state, device]() {
    if (!sink_) return;
    sink_->Success(EncodableValue(EncodableMap{
        {EncodableValue("type"), EncodableValue("conn")},
        {EncodableValue("transport"), EncodableValue(transport)},
        {EncodableValue("state"), EncodableValue(state)},
        {EncodableValue("device"), EncodableValue(device)},
    }));
  });
}

void Elm327Plugin::Register(flutter::BinaryMessenger* messenger, HWND hwnd) {
  // UI スレッド用の隠しウィンドウを作成（messenger を呼ぶスレッド = UI スレッドで作成されること）。
  WNDCLASS wc = {};
  wc.lpfnWndProc = &Elm327Plugin::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kUiWndClass;
  RegisterClass(&wc);
  ui_hwnd_ = CreateWindowEx(0, kUiWndClass, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, wc.hInstance, nullptr);

  control_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elm327/control",
      &flutter::StandardMethodCodec::GetInstance());
  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "elm327/events",
      &flutter::StandardMethodCodec::GetInstance());

  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = std::move(sink);
            return nullptr;
          },
          [this](const EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = nullptr;
            return nullptr;
          }));

  control_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "capabilities") {
          result->Success(EncodableValue(EncodableList{
              EncodableValue("ble"), EncodableValue("spp")}));
        } else if (method == "startBle") {
          // Task 3 で ble_ を起動。引数 profile を取得しておく。
          result->Success();
        } else if (method == "stopBle") {
          result->Success();
        } else if (method == "startSpp") {
          // Task 4 で spp_ を起動。
          result->Success();
        } else if (method == "stopSpp") {
          result->Success();
        } else if (method == "send") {
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
```

> 注: `startBle/send` の引数取り出し（`std::get<EncodableMap>(*call.arguments())` から `profile`/`transport`/`bytes` を読む）と実サーバ呼び出しは Task 3/4 で追記する。本タスクでは契約面（capabilities と各メソッドの受理、イベント形状、UI マーシャリング）を確立する。

- [ ] **Step 3: flutter_window.cpp からプラグイン登録**

`windows/runner/flutter_window.cpp` の `OnCreate()` 内、`flutter_controller_` 構築後・`RegisterPlugins` 付近に追加:
```cpp
#include "elm327_plugin.h"
// ... メンバに std::unique_ptr<Elm327Plugin> elm327_plugin_; を FlutterWindow クラス（flutter_window.h）に追加 ...

// OnCreate() 内、flutter_controller_->engine() 取得後:
elm327_plugin_ = std::make_unique<Elm327Plugin>();
elm327_plugin_->Register(
    flutter_controller_->engine()->messenger(), GetHandle());
```
`windows/runner/flutter_window.h` に `#include "elm327_plugin.h"` と
`std::unique_ptr<Elm327Plugin> elm327_plugin_;` メンバを追加。

- [ ] **Step 4: CMake に新規ソース追加**

`windows/runner/CMakeLists.txt` の `add_executable(${BINARY_NAME} ... )` のソース列挙に追記:
```cmake
  "elm327_plugin.cpp"
```

- [ ] **Step 5: ビルド確認（Windows 機）**

Run: `flutter build windows --debug`
Expected: BUILD SUCCESSFUL。アプリ起動時に Dart の `init()` が `capabilities()` を呼び、UI が BLE/SPP 両ボタンを表示する（接続はまだ不可）。

- [ ] **Step 6: Commit**

```bash
git add windows/
git commit -m "feat(windows): Elm327Plugin (チャネル登録・UIスレッドマーシャリング・capabilities)"
```

---

## Task 3: BleGattServer（C++/WinRT・GattServiceProvider）

**Files:**
- Create: `windows/runner/ble_gatt_server.h`
- Create: `windows/runner/ble_gatt_server.cpp`
- Modify: `windows/runner/elm327_plugin.cpp`（`startBle`/`stopBle`/`send(ble)` を結線）
- Modify: `windows/runner/CMakeLists.txt`

**Interfaces:**
- Consumes: WinRT `Windows.Devices.Bluetooth.GenericAttributeProfile`。`Elm327Plugin::EmitRx/EmitConn`。
- Produces:
  - `class BleGattServer { BleGattServer(OnRx, OnConn); void Start(bool useFff0); void Send(const std::vector<uint8_t>&); void Stop(); };`
    ここで `using OnRx = std::function<void(const std::vector<uint8_t>&)>;`、
    `using OnConn = std::function<void(const std::string& state, const std::string& device)>;`。

- [ ] **Step 1: ヘッダ作成**

`windows/runner/ble_gatt_server.h`:
```cpp
#ifndef RUNNER_BLE_GATT_SERVER_H_
#define RUNNER_BLE_GATT_SERVER_H_

#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>

#include <functional>
#include <string>
#include <vector>

class BleGattServer {
 public:
  using OnRx = std::function<void(const std::vector<uint8_t>&)>;
  using OnConn = std::function<void(const std::string&, const std::string&)>;

  BleGattServer(OnRx on_rx, OnConn on_conn);
  void Start(bool use_fff0);
  void Send(const std::vector<uint8_t>& bytes);
  void Stop();

 private:
  OnRx on_rx_;
  OnConn on_conn_;
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProvider provider_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic notify_char_{nullptr};
  winrt::event_token write_token_{};
  winrt::event_token subscribe_token_{};
};

#endif  // RUNNER_BLE_GATT_SERVER_H_
```

- [ ] **Step 2: 実装作成**

`windows/runner/ble_gatt_server.cpp`:
```cpp
#include "ble_gatt_server.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Foundation;

namespace {
guid Uuid16(uint16_t s) {
  // 0000xxxx-0000-1000-8000-00805F9B34FB
  return guid{ static_cast<uint32_t>(0x00000000u | (static_cast<uint32_t>(s) << 16)),
               0x0000, 0x1000,
               { 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB } };
}
std::vector<uint8_t> BufferToVector(const IBuffer& buf) {
  std::vector<uint8_t> out(buf.Length());
  if (buf.Length() > 0) {
    DataReader reader = DataReader::FromBuffer(buf);
    reader.ReadBytes(array_view<uint8_t>(out.data(), out.data() + out.size()));
  }
  return out;
}
IBuffer VectorToBuffer(const std::vector<uint8_t>& v) {
  DataWriter writer;
  writer.WriteBytes(array_view<const uint8_t>(v.data(), v.data() + v.size()));
  return writer.DetachBuffer();
}
}  // namespace

BleGattServer::BleGattServer(OnRx on_rx, OnConn on_conn)
    : on_rx_(std::move(on_rx)), on_conn_(std::move(on_conn)) {}

void BleGattServer::Start(bool use_fff0) {
  guid serviceUuid = Uuid16(use_fff0 ? 0xFFF0 : 0xFFE0);
  guid writeUuid   = Uuid16(use_fff0 ? 0xFFF2 : 0xFFE1);
  guid notifyUuid  = Uuid16(use_fff0 ? 0xFFF1 : 0xFFE1);

  auto providerResult = GattServiceProvider::CreateAsync(serviceUuid).get();
  provider_ = providerResult.ServiceProvider();
  auto service = provider_.Service();

  if (notifyUuid == writeUuid) {
    // FFE0: 単一特性（Write + WriteWithoutResponse + Notify）
    GattLocalCharacteristicParameters params;
    params.CharacteristicProperties(
        GattCharacteristicProperties::Write |
        GattCharacteristicProperties::WriteWithoutResponse |
        GattCharacteristicProperties::Notify);
    auto res = service.CreateCharacteristicAsync(writeUuid, params).get();
    notify_char_ = res.Characteristic();
  } else {
    // FFF0: write(FFF2) と notify(FFF1) を分離
    GattLocalCharacteristicParameters wparams;
    wparams.CharacteristicProperties(
        GattCharacteristicProperties::Write |
        GattCharacteristicProperties::WriteWithoutResponse);
    service.CreateCharacteristicAsync(writeUuid, wparams).get();

    GattLocalCharacteristicParameters nparams;
    nparams.CharacteristicProperties(GattCharacteristicProperties::Notify);
    auto nres = service.CreateCharacteristicAsync(notifyUuid, nparams).get();
    notify_char_ = nres.Characteristic();
  }

  // 書き込み受信（write 特性は単一/分離どちらでも、write 可能な特性で WriteRequested が発火）。
  // 単一特性時は notify_char_ が write も担う。分離時は write 特性側に登録する必要があるため、
  // ここでは全特性に対してハンドラを張る方針にする（実装計画では notify_char_ が write を兼ねる
  // FFE0 を主対象とし、FFF0 の write 特性ハンドラ登録は Windows 機で確認・補完する）。
  write_token_ = notify_char_.WriteRequested(
      [this](GattLocalCharacteristic const&, GattWriteRequestedEventArgs const& args) -> IAsyncAction {
        auto deferral = args.GetDeferral();
        auto request = co_await args.GetRequestAsync();
        auto bytes = BufferToVector(request.Value());
        if (on_rx_) on_rx_(bytes);
        if (request.Option() == GattWriteOption::WriteWithResponse) {
          request.Respond();
        }
        deferral.Complete();
      });

  subscribe_token_ = notify_char_.SubscribedClientsChanged(
      [this](GattLocalCharacteristic const& ch, IInspectable const&) {
        bool connected = ch.SubscribedClients().Size() > 0;
        if (on_conn_) on_conn_(connected ? "connected" : "disconnected", "");
      });

  GattServiceProviderAdvertisingParameters adv;
  adv.IsConnectable(true);
  adv.IsDiscoverable(true);
  provider_.StartAdvertising(adv);
}

void BleGattServer::Send(const std::vector<uint8_t>& bytes) {
  if (!notify_char_) return;
  // MTU 20 バイトで分割 Notify
  size_t i = 0;
  while (i < bytes.size()) {
    size_t end = (i + 20 < bytes.size()) ? i + 20 : bytes.size();
    std::vector<uint8_t> chunk(bytes.begin() + i, bytes.begin() + end);
    notify_char_.NotifyValueAsync(VectorToBuffer(chunk));
    i = end;
  }
}

void BleGattServer::Stop() {
  if (provider_) {
    try { provider_.StopAdvertising(); } catch (...) {}
    provider_ = nullptr;
  }
  notify_char_ = nullptr;
}
```

> 注（Windows 機で確認）: `GattServiceProviderAdvertisingParameters` にローカル名 `OBDII` を載せる方法は
> Windows のバージョンにより異なる（広告にはサービス UUID が載るが、デバイス名はアダプタ名に依存する
> ことがある）。デバイス名のカスタマイズが必要なら Windows 機で調整する。FFF0 の write 特性側
> `WriteRequested` 登録漏れがないか（分離プロファイル使用時）も実機で確認する。

- [ ] **Step 3: Elm327Plugin に結線**

`windows/runner/elm327_plugin.cpp` の `#include "ble_gatt_server.h"` を追加し、ハンドラを更新:
```cpp
} else if (method == "startBle") {
  bool fff0 = false;
  if (auto* args = std::get_if<EncodableMap>(call.arguments())) {
    auto it = args->find(EncodableValue("profile"));
    if (it != args->end()) {
      fff0 = (std::get<std::string>(it->second) == "fff0");
    }
  }
  ble_ = std::make_unique<BleGattServer>(
      [this](const std::vector<uint8_t>& b) { EmitRx("ble", b); },
      [this](const std::string& s, const std::string& d) { EmitConn("ble", s, d); });
  ble_->Start(fff0);
  result->Success();
} else if (method == "stopBle") {
  if (ble_) { ble_->Stop(); ble_.reset(); }
  result->Success();
} else if (method == "send") {
  auto* args = std::get_if<EncodableMap>(call.arguments());
  if (args) {
    auto t = std::get<std::string>(args->at(EncodableValue("transport")));
    auto bytes = std::get<std::vector<uint8_t>>(args->at(EncodableValue("bytes")));
    if (t == "ble" && ble_) ble_->Send(bytes);
    else if (t == "spp" && spp_) { /* Task 4 */ }
  }
  result->Success();
}
```
（`#include "ble_gatt_server.h"`、`#include <variant>` を先頭へ。`bytes` は Dart 側 `Uint8List` →
Windows では `std::vector<uint8_t>` にデコードされる。）

- [ ] **Step 4: CMake に追加**

`windows/runner/CMakeLists.txt` のソースに `"ble_gatt_server.cpp"` を追記。

- [ ] **Step 5: ビルド確認（Windows 機）**

Run: `flutter build windows --debug`
Expected: BUILD SUCCESSFUL。型不一致（WinRT async/guid 等）でビルド修正が入る可能性あり — その場で修正。

- [ ] **Step 6: Commit**

```bash
git add windows/
git commit -m "feat(windows): BLE GATTサーバ(GattServiceProvider, FFE0/FFF0)"
```

---

## Task 4: SppServer（C++/WinRT・RfcommServiceProvider）

**Files:**
- Create: `windows/runner/spp_server.h`
- Create: `windows/runner/spp_server.cpp`
- Modify: `windows/runner/elm327_plugin.cpp`（`startSpp`/`stopSpp`/`send(spp)` を結線）
- Modify: `windows/runner/CMakeLists.txt`

**Interfaces:**
- Consumes: WinRT `Windows.Devices.Bluetooth.Rfcomm`, `Windows.Networking.Sockets`, `Windows.Storage.Streams`。
- Produces: `class SppServer { SppServer(OnRx, OnConn); void Start(); void Send(const std::vector<uint8_t>&); void Stop(); };`（OnRx/OnConn は BleGattServer と同型）。

- [ ] **Step 1: ヘッダ作成**

`windows/runner/spp_server.h`:
```cpp
#ifndef RUNNER_SPP_SERVER_H_
#define RUNNER_SPP_SERVER_H_

#include <winrt/Windows.Devices.Bluetooth.Rfcomm.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>

#include <functional>
#include <string>
#include <vector>

class SppServer {
 public:
  using OnRx = std::function<void(const std::vector<uint8_t>&)>;
  using OnConn = std::function<void(const std::string&, const std::string&)>;

  SppServer(OnRx on_rx, OnConn on_conn);
  void Start();
  void Send(const std::vector<uint8_t>& bytes);
  void Stop();

 private:
  winrt::Windows::Foundation::IAsyncAction ReadLoop(
      winrt::Windows::Networking::Sockets::StreamSocket socket);

  OnRx on_rx_;
  OnConn on_conn_;
  winrt::Windows::Devices::Bluetooth::Rfcomm::RfcommServiceProvider provider_{nullptr};
  winrt::Windows::Networking::Sockets::StreamSocketListener listener_{nullptr};
  winrt::Windows::Networking::Sockets::StreamSocket socket_{nullptr};
  winrt::Windows::Storage::Streams::DataWriter writer_{nullptr};
  winrt::event_token conn_token_{};
  bool running_ = false;
};

#endif  // RUNNER_SPP_SERVER_H_
```

- [ ] **Step 2: 実装作成**

`windows/runner/spp_server.cpp`:
```cpp
#include "spp_server.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.Bluetooth.h>

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth::Rfcomm;
using namespace winrt::Windows::Networking::Sockets;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Foundation;

namespace {
// 00001101-0000-1000-8000-00805F9B34FB
const guid kSppUuid{ 0x00001101, 0x0000, 0x1000,
                     { 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB } };
}  // namespace

SppServer::SppServer(OnRx on_rx, OnConn on_conn)
    : on_rx_(std::move(on_rx)), on_conn_(std::move(on_conn)) {}

void SppServer::Start() {
  running_ = true;
  // 非同期に待受開始
  [this]() -> IAsyncAction {
    provider_ = co_await RfcommServiceProvider::CreateAsync(
        RfcommServiceId::FromUuid(kSppUuid));
    listener_ = StreamSocketListener();
    conn_token_ = listener_.ConnectionReceived(
        [this](StreamSocketListener const&,
               StreamSocketListenerConnectionReceivedEventArgs const& args) {
          socket_ = args.Socket();
          writer_ = DataWriter(socket_.OutputStream());
          if (on_conn_) on_conn_("connected", "");
          ReadLoop(socket_);
        });
    co_await listener_.BindServiceNameAsync(
        provider_.ServiceId().AsString(),
        SocketProtectionLevel::BluetoothEncryptionAllowNullAuthentication);
    // SDP 属性（任意）。サービス名等は必要なら設定。
    provider_.StartAdvertising(listener_);
  }();
}

IAsyncAction SppServer::ReadLoop(StreamSocket socket) {
  try {
    DataReader reader(socket.InputStream());
    reader.InputStreamOptions(InputStreamOptions::Partial);
    while (running_) {
      uint32_t got = co_await reader.LoadAsync(1024);
      if (got == 0) break;  // 切断
      std::vector<uint8_t> buf(got);
      reader.ReadBytes(array_view<uint8_t>(buf.data(), buf.data() + got));
      if (on_rx_) on_rx_(buf);
    }
  } catch (...) {
  }
  if (on_conn_) on_conn_("disconnected", "");
}

void SppServer::Send(const std::vector<uint8_t>& bytes) {
  if (!writer_) return;
  try {
    writer_.WriteBytes(array_view<const uint8_t>(bytes.data(), bytes.data() + bytes.size()));
    writer_.StoreAsync();  // fire-and-forget（順序は WinRT が保証）
  } catch (...) {}
}

void SppServer::Stop() {
  running_ = false;
  try { if (provider_) provider_.StopAdvertising(); } catch (...) {}
  try { if (socket_) socket_.Close(); } catch (...) {}
  try { if (listener_) listener_.Close(); } catch (...) {}
  provider_ = nullptr; listener_ = nullptr; socket_ = nullptr; writer_ = nullptr;
}
```

> 注（Windows 機で確認）: `provider_.ServiceId().AsString()` を `BindServiceNameAsync` に渡す方法と
> `StartAdvertising(listener_)` の引数の正確な型/順序は WinRT バージョン依存。`StoreAsync` の
> fire-and-forget は連続送信時の順序を確認（必要なら逐次 await のシリアライズへ変更）。

- [ ] **Step 3: Elm327Plugin に結線**

`windows/runner/elm327_plugin.cpp` に `#include "spp_server.h"` を追加し:
```cpp
} else if (method == "startSpp") {
  spp_ = std::make_unique<SppServer>(
      [this](const std::vector<uint8_t>& b) { EmitRx("spp", b); },
      [this](const std::string& s, const std::string& d) { EmitConn("spp", s, d); });
  spp_->Start();
  result->Success();
} else if (method == "stopSpp") {
  if (spp_) { spp_->Stop(); spp_.reset(); }
  result->Success();
}
```
`send` の `spp` 分岐（Task 3 のプレースホルダ）を `if (t == "spp" && spp_) spp_->Send(bytes);` に更新。

- [ ] **Step 4: CMake に追加**

`windows/runner/CMakeLists.txt` のソースに `"spp_server.cpp"` を追記。

- [ ] **Step 5: ビルド確認（Windows 機）**

Run: `flutter build windows --debug`
Expected: BUILD SUCCESSFUL（WinRT 型修正が入る可能性あり）。

- [ ] **Step 6: Commit**

```bash
git add windows/
git commit -m "feat(windows): SPP(RFCOMM)サーバ(RfcommServiceProvider)"
```

---

## Task 5: README 更新と Windows 検証手順

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: Windows ビルド/権限/検証手順のドキュメント。

- [ ] **Step 1: README に Windows セクション追加**

`README.md` に追記:
- 対応表に Windows（BLE+SPP）を追加。
- ビルド: `flutter config --enable-windows-desktop` → `flutter build windows` / `flutter run -d windows`（要 Windows 10 1703+ / Visual Studio C++ ワークロード）。
- 既知の制約: 非パッケージ(Win32)アプリでの WinRT BLE ペリフェラル/RFCOMM の挙動は環境依存。広告デバイス名はアダプタ名に依存する場合あり。
- 手動結合確認チェックリスト（Windows）: 別デバイス/自作クライアントから (1) BLE 接続→ATZ→ELM327 v1.5、010C→RPM、(2) SPP 接続→同様。

- [ ] **Step 2: Dart 側回帰確認（macOS でも可）**

Run: `flutter test`
Expected: 既存テスト全合格（Dart 側は無変更のため）。

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README に Windows(BLE+SPP) ビルド/検証手順を追加"
```

---

## Self-Review チェック結果

- **Spec coverage**: Windows スキャフォールド(Task 1)、チャネル登録・capabilities=["ble","spp"]・UI スレッドマーシャリング(Task 2)、BLE GATTサーバ FFE0/FFF0(Task 3)、SPP RFCOMM(Task 4)、ドキュメント(Task 5) を網羅。Dart 契約（チャネル名・メソッド・引数キー・イベント形状）を全タスクで踏襲。
- **環境制約の明示**: 全ビルド/実行ステップを「Windows 機で実施」と明記。macOS 作業者はコード作成＋静的レビューまで、ビルド/動作確認は Windows 機で行う旨を Global Constraints と各タスクに記載。
- **Placeholder ではない段階実装**: Task 2 で各メソッドを受理（capabilities は完全実装）、Task 3/4 で BLE/SPP の実体を差し込む段階構成。各差し込み箇所を具体コードで明示。
- **Type consistency**: `OnRx`/`OnConn` シグネチャ、`EmitRx("ble"/"spp",...)`/`EmitConn`、`send` の `transport`/`bytes` デコード、capabilities=["ble","spp"] を Task 2/3/4 で統一。
- **既知リスク**: WinRT の async/guid/広告名・FFF0 write ハンドラ・StoreAsync 順序など、実機で確認・補完すべき点を各タスクの注記に明示。
