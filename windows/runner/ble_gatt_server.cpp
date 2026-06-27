#include "ble_gatt_server.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Foundation;

namespace {

// Builds a Bluetooth SIG 16-bit UUID: 0000xxxx-0000-1000-8000-00805F9B34FB.
// The 16-bit value occupies the LOW 16 bits of Data1 (e.g. FFE0 -> 0x0000FFE0).
guid Uuid16(uint16_t s) {
  return guid{static_cast<uint32_t>(s),
              0x0000,
              0x1000,
              {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
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
  if (!v.empty()) {
    writer.WriteBytes(array_view<const uint8_t>(v.data(), v.data() + v.size()));
  }
  return writer.DetachBuffer();
}

}  // namespace

BleGattServer::BleGattServer(OnRx on_rx, OnConn on_conn)
    : on_rx_(std::move(on_rx)), on_conn_(std::move(on_conn)) {}

void BleGattServer::Start(bool use_fff0) {
  // Run setup as a fire-and-forget coroutine: the channel handler calls Start()
  // on the UI/STA thread, where a blocking .get() on a WinRT async would
  // deadlock the message pump. co_await keeps the UI thread responsive.
  [this, use_fff0]() -> fire_and_forget {
    const guid serviceUuid = Uuid16(use_fff0 ? 0xFFF0 : 0xFFE0);
    const guid writeUuid = Uuid16(use_fff0 ? 0xFFF2 : 0xFFE1);
    const guid notifyUuid = Uuid16(use_fff0 ? 0xFFF1 : 0xFFE1);

    auto providerResult = co_await GattServiceProvider::CreateAsync(serviceUuid);
    provider_ = providerResult.ServiceProvider();
    auto service = provider_.Service();

    // Forwards a write request to onRx and acks if the client wants a response.
    auto writeHandler =
        [this](GattLocalCharacteristic const&,
               GattWriteRequestedEventArgs const& args) -> fire_and_forget {
      auto deferral = args.GetDeferral();
      auto request = co_await args.GetRequestAsync();
      auto bytes = BufferToVector(request.Value());
      if (on_rx_) on_rx_(bytes);
      if (request.Option() == GattWriteOption::WriteWithResponse) {
        request.Respond();
      }
      deferral.Complete();
    };

    if (notifyUuid == writeUuid) {
      // FFE0: a single characteristic carries write + notify.
      GattLocalCharacteristicParameters params;
      params.CharacteristicProperties(
          GattCharacteristicProperties::Write |
          GattCharacteristicProperties::WriteWithoutResponse |
          GattCharacteristicProperties::Notify);
      auto res = co_await service.CreateCharacteristicAsync(writeUuid, params);
      notify_char_ = res.Characteristic();
      notify_write_token_ = notify_char_.WriteRequested(writeHandler);
    } else {
      // FFF0: separate write (FFF2) and notify (FFF1) characteristics.
      GattLocalCharacteristicParameters wparams;
      wparams.CharacteristicProperties(
          GattCharacteristicProperties::Write |
          GattCharacteristicProperties::WriteWithoutResponse);
      auto wres = co_await service.CreateCharacteristicAsync(writeUuid, wparams);
      write_char_ = wres.Characteristic();
      write_char_token_ = write_char_.WriteRequested(writeHandler);

      GattLocalCharacteristicParameters nparams;
      nparams.CharacteristicProperties(GattCharacteristicProperties::Notify);
      auto nres = co_await service.CreateCharacteristicAsync(notifyUuid, nparams);
      notify_char_ = nres.Characteristic();
    }

    subscribe_token_ = notify_char_.SubscribedClientsChanged(
        [this](GattLocalCharacteristic const& ch, IInspectable const&) {
          bool connected = ch.SubscribedClients().Size() > 0;
          if (on_conn_) on_conn_(connected ? "connected" : "disconnected", "");
        });

    GattServiceProviderAdvertisingParameters adv;
    adv.IsConnectable(true);
    adv.IsDiscoverable(true);
    provider_.StartAdvertising(adv);
  }();
}

void BleGattServer::Send(const std::vector<uint8_t>& bytes) {
  if (!notify_char_) return;
  if (notify_char_.SubscribedClients().Size() == 0) return;  // no subscriber
  // Chunk to the conventional 20-byte ATT payload and notify each piece.
  // NotifyValueAsync is queued by the stack; order is preserved.
  size_t i = 0;
  while (i < bytes.size()) {
    size_t end = (i + 20 < bytes.size()) ? i + 20 : bytes.size();
    std::vector<uint8_t> chunk(bytes.begin() + i, bytes.begin() + end);
    notify_char_.NotifyValueAsync(VectorToBuffer(chunk));
    i = end;
  }
}

void BleGattServer::Stop() {
  // Revoke event handlers before releasing the characteristics.
  if (notify_char_) {
    if (notify_write_token_) notify_char_.WriteRequested(notify_write_token_);
    if (subscribe_token_) {
      notify_char_.SubscribedClientsChanged(subscribe_token_);
    }
  }
  if (write_char_ && write_char_token_) {
    write_char_.WriteRequested(write_char_token_);
  }
  if (provider_) {
    try {
      provider_.StopAdvertising();
    } catch (...) {
    }
    provider_ = nullptr;
  }
  notify_char_ = nullptr;
  write_char_ = nullptr;
}
