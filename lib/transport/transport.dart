enum TransportType { ble, spp, tcp }

extension TransportTypeName on TransportType {
  String get wire => name; // 'ble' / 'spp' / 'tcp'
  String get label => switch (this) {
        TransportType.ble => 'BLE',
        TransportType.spp => 'SPP',
        TransportType.tcp => 'TCP',
      };
  static TransportType fromWire(String s) => switch (s) {
        'spp' => TransportType.spp,
        'tcp' => TransportType.tcp,
        _ => TransportType.ble,
      };
}
