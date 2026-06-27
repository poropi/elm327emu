#ifndef RUNNER_SPP_SERVER_H_
#define RUNNER_SPP_SERVER_H_

#include <winrt/Windows.Devices.Bluetooth.Rfcomm.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>

#include <functional>
#include <string>
#include <vector>

// Classic SPP (RFCOMM) server backed by WinRT RfcommServiceProvider +
// StreamSocketListener. Single-client (the ELM327 use case).
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
  winrt::Windows::Devices::Bluetooth::Rfcomm::RfcommServiceProvider provider_{
      nullptr};
  winrt::Windows::Networking::Sockets::StreamSocketListener listener_{nullptr};
  winrt::Windows::Networking::Sockets::StreamSocket socket_{nullptr};
  winrt::Windows::Storage::Streams::DataWriter writer_{nullptr};
  winrt::event_token conn_token_{};
  bool running_ = false;
};

#endif  // RUNNER_SPP_SERVER_H_
