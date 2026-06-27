#ifndef RUNNER_ELM327_PLUGIN_H_
#define RUNNER_ELM327_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/encodable_value.h>
#include <flutter/binary_messenger.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

class BleGattServer;  // Task 3
class SppServer;      // Task 4

// Registers the ELM327 MethodChannel/EventChannel and routes calls to the
// native BLE/SPP transports. Mirrors the Android (MainActivity) and macOS
// (AppDelegate) in-runner registration approach.
class Elm327Plugin {
 public:
  Elm327Plugin();
  ~Elm327Plugin();

  // |messenger| is engine->messenger(); must be called on the UI thread so the
  // hidden message-only window is created on that thread.
  void Register(flutter::BinaryMessenger* messenger);

  // Called from WinRT callback threads; marshals to the UI thread before
  // touching the EventSink (channels are not thread-safe).
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

  HWND ui_hwnd_ = nullptr;  // message-only window for UI-thread marshaling
};

#endif  // RUNNER_ELM327_PLUGIN_H_
