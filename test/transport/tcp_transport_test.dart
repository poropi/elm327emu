import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:elm327emu/transport/tcp_transport.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('1 接続を受けて送受信し、2 本目は切り、disconnect で切れる', () async {
    final t = TcpTransport(port: 0);
    await t.start();
    expect(t.isListening, isTrue);
    final conns = <String>[];
    t.onConnection.listen(conns.add);
    final got = <int>[];
    t.onReceive.listen(got.addAll);

    final c1 = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    final c1Data = <int>[];
    final c1Done = Completer<void>();
    c1.listen(c1Data.addAll, onDone: c1Done.complete);
    await _settle();
    expect(conns.single, startsWith('connected 127.0.0.1:'));
    expect(t.hasClient, isTrue);

    c1.add('ATI\r'.codeUnits);
    await c1.flush();
    await _settle();
    expect(String.fromCharCodes(got), 'ATI\r');

    t.send('ELM327 v1.5\r\r>'.codeUnits);
    await _settle();
    expect(String.fromCharCodes(c1Data), 'ELM327 v1.5\r\r>');

    final c2 = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    final c2Done = Completer<void>();
    c2.listen((_) {}, onDone: c2Done.complete, onError: (Object _) => c2Done.complete());
    await c2Done.future.timeout(const Duration(seconds: 2));

    await t.disconnect();
    await c1Done.future.timeout(const Duration(seconds: 2));
    await _settle();
    expect(conns.last, 'disconnected');
    expect(t.hasClient, isFalse);

    await t.stop();
    expect(t.isListening, isFalse);
    c1.destroy();
    c2.destroy();
  });

  test('クライアント側から切っても disconnected', () async {
    final t = TcpTransport(port: 0);
    await t.start();
    final conns = <String>[];
    t.onConnection.listen(conns.add);
    final c = await Socket.connect(InternetAddress.loopbackIPv4, t.port);
    await _settle();
    await c.close();
    await _settle();
    expect(conns, [startsWith('connected'), 'disconnected']);
    await t.stop();
  });
}
