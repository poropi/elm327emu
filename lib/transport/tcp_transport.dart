import 'dart:async';
import 'dart:io';

/// 開発用の TCP サーバ（127.0.0.1、同時 1 接続。2 本目は即切断）。python-OBD などの検証に使う。
class TcpTransport {
  TcpTransport({int port = 35000}) : _requestedPort = port;

  final int _requestedPort;
  ServerSocket? _server;
  Socket? _client;
  final _rx = StreamController<List<int>>.broadcast();
  final _conn = StreamController<String>.broadcast();

  Stream<List<int>> get onReceive => _rx.stream;

  /// 'connected <アドレス>:<ポート>' / 'disconnected'
  Stream<String> get onConnection => _conn.stream;

  bool get isListening => _server != null;
  bool get hasClient => _client != null;
  int get port => _server?.port ?? _requestedPort;

  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _requestedPort);
    _server = server;
    server.listen(_accept);
  }

  void _accept(Socket s) {
    if (_client != null) {
      s.destroy();
      return;
    }
    _client = s;
    s.setOption(SocketOption.tcpNoDelay, true);
    _conn.add('connected ${s.remoteAddress.address}:${s.remotePort}');
    s.listen(
      _rx.add,
      onDone: () => _drop(s),
      onError: (Object _) => _drop(s),
      cancelOnError: true,
    );
  }

  void _drop(Socket s) {
    if (!identical(_client, s)) return;
    _client = null;
    s.destroy();
    _conn.add('disconnected');
  }

  void send(List<int> bytes) {
    final c = _client;
    if (c == null) return;
    try {
      c.add(bytes);
    } on Object {
      _drop(c); // 切断直後の書き込み
    }
  }

  Future<void> disconnect() async {
    final c = _client;
    if (c != null) _drop(c);
  }

  Future<void> stop() async {
    await disconnect();
    await _server?.close();
    _server = null;
  }
}
