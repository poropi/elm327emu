#ifndef RUNNER_BLE_GATT_SERVER_H_
#define RUNNER_BLE_GATT_SERVER_H_

#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>

#include <functional>
#include <string>
#include <vector>

// BLE peripheral (GATT server) backed by WinRT GattServiceProvider.
// FFE0 profile uses a single FFE1 characteristic (write + notify); FFF0 uses
// separate FFF2 (write) and FFF1 (notify) characteristics.
class BleGattServer {
 public:
  using OnRx = std::function<void(const std::vector<uint8_t>&)>;
  using OnConn = std::function<void(const std::string&, const std::string&)>;

  BleGattServer(OnRx on_rx, OnConn on_conn);
  void Start(bool use_fff0);
  void Send(const std::vector<uint8_t>& bytes);  // MTU(20)-chunked notify
  void Stop();

 private:
  OnRx on_rx_;
  OnConn on_conn_;
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProvider
      provider_{nullptr};
  // Characteristic used for notifications (and, for FFE0, also writes).
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic
      notify_char_{nullptr};
  // For FFF0: the separate write characteristic. Null for FFE0.
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic
      write_char_{nullptr};
  winrt::event_token notify_write_token_{};
  winrt::event_token write_char_token_{};
  winrt::event_token subscribe_token_{};
};

#endif  // RUNNER_BLE_GATT_SERVER_H_
