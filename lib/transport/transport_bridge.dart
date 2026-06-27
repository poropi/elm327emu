import 'package:flutter/services.dart';
import 'transport.dart';

/// ネイティブ Transport（BLE/SPP サーバ）への橋渡し。
class TransportBridge {
  static const _control = MethodChannel('elm327/control');
  static const _events = EventChannel('elm327/events');

  Stream<Map<dynamic, dynamic>>? _eventStream;

  Stream<Map<dynamic, dynamic>> get _raw =>
      _eventStream ??= _events.receiveBroadcastStream().cast<Map>();

  Future<List<TransportType>> capabilities() async {
    final caps = await _control.invokeMethod<List<dynamic>>('capabilities');
    return (caps ?? [])
        .map((e) => TransportTypeName.fromWire(e as String))
        .toList();
  }

  Future<void> startBle({bool useFff0 = false}) =>
      _control.invokeMethod('startBle', {'profile': useFff0 ? 'fff0' : 'ffe0'});
  Future<void> stopBle() => _control.invokeMethod('stopBle');
  Future<void> startSpp() => _control.invokeMethod('startSpp');
  Future<void> stopSpp() => _control.invokeMethod('stopSpp');

  Future<void> send(TransportType t, List<int> bytes) => _control.invokeMethod(
      'send', {'transport': t.wire, 'bytes': Uint8List.fromList(bytes)});

  Stream<({TransportType transport, List<int> bytes})> get onReceive => _raw
      .where((e) => e['type'] == 'rx')
      .map((e) => (
            transport: TransportTypeName.fromWire(e['transport'] as String),
            bytes: (e['bytes'] as List).cast<int>(),
          ));

  Stream<({TransportType transport, String state, String device})>
      get onConnection => _raw.where((e) => e['type'] == 'conn').map((e) => (
            transport: TransportTypeName.fromWire(e['transport'] as String),
            state: e['state'] as String,
            device: (e['device'] as String?) ?? '',
          ));
}
