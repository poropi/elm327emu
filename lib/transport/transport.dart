enum TransportType { ble, spp }

extension TransportTypeName on TransportType {
  String get wire => name; // 'ble' / 'spp'
  static TransportType fromWire(String s) =>
      s == 'spp' ? TransportType.spp : TransportType.ble;
}
