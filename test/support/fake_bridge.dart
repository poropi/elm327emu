import 'dart:async';

import 'package:elm327emu/transport/transport.dart';
import 'package:elm327emu/transport/transport_bridge.dart';

/// Platform Channel を使わない TransportBridge。
class FakeTransportBridge extends TransportBridge {
  final rx = StreamController<({TransportType transport, List<int> bytes})>.broadcast(sync: true);
  final conn = StreamController<({TransportType transport, String state, String device})>.broadcast(sync: true);
  final sent = <(TransportType, List<int>)>[];
  final calls = <String>[];

  String sentText(TransportType t) => sent.where((e) => e.$1 == t).map((e) => String.fromCharCodes(e.$2)).join();

  @override
  Future<List<TransportType>> capabilities() async => [TransportType.ble, TransportType.spp];
  @override
  Stream<({TransportType transport, List<int> bytes})> get onReceive => rx.stream;
  @override
  Stream<({TransportType transport, String state, String device})> get onConnection => conn.stream;
  @override
  Future<void> send(TransportType t, List<int> bytes) async => sent.add((t, bytes));
  @override
  Future<void> startBle({bool useFff0 = false}) async => calls.add('startBle:$useFff0');
  @override
  Future<void> stopBle() async => calls.add('stopBle');
  @override
  Future<void> startSpp() async => calls.add('startSpp');
  @override
  Future<void> stopSpp() async => calls.add('stopSpp');
  @override
  Future<void> disconnect(TransportType t) async => calls.add('disconnect:${t.wire}');
}
