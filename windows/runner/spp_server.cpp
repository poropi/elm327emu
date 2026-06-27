#include "spp_server.h"

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Foundation.Collections.h>

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth::Rfcomm;
using namespace winrt::Windows::Networking::Sockets;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Foundation;

namespace {
// SPP service class UUID: 00001101-0000-1000-8000-00805F9B34FB.
const guid kSppUuid{0x00001101,
                    0x0000,
                    0x1000,
                    {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
}  // namespace

SppServer::SppServer(OnRx on_rx, OnConn on_conn)
    : on_rx_(std::move(on_rx)), on_conn_(std::move(on_conn)) {}

void SppServer::Start() {
  running_ = true;
  // Begin listening asynchronously; capture this (lifetime owned by plugin).
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
    provider_.StartAdvertising(listener_);
  }();
}

IAsyncAction SppServer::ReadLoop(StreamSocket socket) {
  try {
    DataReader reader(socket.InputStream());
    reader.InputStreamOptions(InputStreamOptions::Partial);
    while (running_) {
      uint32_t got = co_await reader.LoadAsync(1024);
      if (got == 0) break;  // peer closed
      std::vector<uint8_t> buf(got);
      reader.ReadBytes(array_view<uint8_t>(buf.data(), buf.data() + got));
      if (on_rx_) on_rx_(buf);
    }
    reader.DetachStream();
  } catch (...) {
  }
  if (on_conn_) on_conn_("disconnected", "");
}

void SppServer::Send(const std::vector<uint8_t>& bytes) {
  if (!writer_ || bytes.empty()) return;
  try {
    writer_.WriteBytes(
        array_view<const uint8_t>(bytes.data(), bytes.data() + bytes.size()));
    writer_.StoreAsync();  // ordered by the stack; fire-and-forget
  } catch (...) {
  }
}

void SppServer::Stop() {
  running_ = false;
  try {
    if (provider_) provider_.StopAdvertising();
  } catch (...) {
  }
  try {
    if (socket_) socket_.Close();
  } catch (...) {
  }
  try {
    if (listener_) listener_.Close();
  } catch (...) {
  }
  provider_ = nullptr;
  listener_ = nullptr;
  socket_ = nullptr;
  writer_ = nullptr;
}
