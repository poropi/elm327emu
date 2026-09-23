import 'ecu_profile.dart';

/// OBD 以外のサービス。Mode 22（ReadDataByIdentifier）と否定応答のみ。
class UdsServices {
  List<int>? handle(
    List<int> request,
    EcuProfile ecu, {
    required bool functional,
  }) {
    if (request.isEmpty) return null;
    final sid = request[0];
    if (functional) return null;
    if (sid == 0x22) {
      if (request.length != 3) return [0x7F, 0x22, 0x13];
      final did = (request[1] << 8) | request[2];
      final value = ecu.dids[did];
      if (value == null) return [0x7F, 0x22, 0x31];
      return [0x62, request[1], request[2], ...value.bytes];
    }
    return [0x7F, sid, 0x11];
  }
}
