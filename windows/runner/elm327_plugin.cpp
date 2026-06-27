#include "elm327_plugin.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <mutex>
#include <queue>
#include <variant>

#include "ble_gatt_server.h"
#include "spp_server.h"

namespace {
constexpr wchar_t kUiWndClass[] = L"Elm327PluginUiSink";
constexpr UINT kWmRunTask = WM_USER + 1;

// Tasks queued from WinRT threads, drained on the UI thread by WndProc.
std::mutex g_task_mutex;
std::queue<std::function<void()>> g_tasks;
}  // namespace

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

Elm327Plugin::Elm327Plugin() = default;
Elm327Plugin::~Elm327Plugin() = default;

LRESULT CALLBACK Elm327Plugin::WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
  if (msg == kWmRunTask) {
    std::function<void()> fn;
    {
      std::lock_guard<std::mutex> lock(g_task_mutex);
      if (!g_tasks.empty()) {
        fn = std::move(g_tasks.front());
        g_tasks.pop();
      }
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

void Elm327Plugin::Register(flutter::BinaryMessenger* messenger) {
  WNDCLASS wc = {};
  wc.lpfnWndProc = &Elm327Plugin::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kUiWndClass;
  RegisterClass(&wc);
  ui_hwnd_ = CreateWindowEx(0, kUiWndClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                            nullptr, wc.hInstance, nullptr);

  control_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elm327/control",
      &flutter::StandardMethodCodec::GetInstance());
  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "elm327/events", &flutter::StandardMethodCodec::GetInstance());

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
          result->Success(EncodableValue(
              EncodableList{EncodableValue("ble"), EncodableValue("spp")}));
        } else if (method == "startBle") {
          bool fff0 = false;
          if (auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue("profile"));
            if (it != args->end()) {
              fff0 = (std::get<std::string>(it->second) == "fff0");
            }
          }
          if (ble_) ble_->Stop();  // idempotent: drop a previous server
          ble_ = std::make_unique<BleGattServer>(
              [this](const std::vector<uint8_t>& b) { EmitRx("ble", b); },
              [this](const std::string& s, const std::string& d) {
                EmitConn("ble", s, d);
              });
          ble_->Start(fff0);
          result->Success();
        } else if (method == "stopBle") {
          if (ble_) {
            ble_->Stop();
            ble_.reset();
          }
          result->Success();
        } else if (method == "startSpp") {
          if (spp_) spp_->Stop();  // idempotent
          spp_ = std::make_unique<SppServer>(
              [this](const std::vector<uint8_t>& b) { EmitRx("spp", b); },
              [this](const std::string& s, const std::string& d) {
                EmitConn("spp", s, d);
              });
          spp_->Start();
          result->Success();
        } else if (method == "stopSpp") {
          if (spp_) {
            spp_->Stop();
            spp_.reset();
          }
          result->Success();
        } else if (method == "send") {
          if (auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto t_it = args->find(EncodableValue("transport"));
            auto b_it = args->find(EncodableValue("bytes"));
            const std::string* t =
                (t_it != args->end())
                    ? std::get_if<std::string>(&t_it->second)
                    : nullptr;
            // Dart sends bytes as a Uint8List -> std::vector<uint8_t>.
            const std::vector<uint8_t>* bytes =
                (b_it != args->end())
                    ? std::get_if<std::vector<uint8_t>>(&b_it->second)
                    : nullptr;
            if (t && bytes) {
              if (*t == "ble" && ble_) {
                ble_->Send(*bytes);
              } else if (*t == "spp" && spp_) {
                spp_->Send(*bytes);
              }
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
