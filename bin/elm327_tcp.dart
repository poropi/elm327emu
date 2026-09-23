import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:elm327emu/app/control_commands.dart';
import 'package:elm327emu/app/emulation_core.dart';
import 'package:elm327emu/elm327/elm_session.dart';
import 'package:elm327emu/transport/tcp_transport.dart';

/// UI なしで ELM327 エミュレータを TCP で待ち受ける（python-OBD などの検証用）。
/// 標準入力 1 行 = 制御コマンド 1 つ（lib/app/control_commands.dart）。
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('port', defaultsTo: '35000')
    ..addFlag('transmission', negatable: false, help: 'トランスミッション ECU を有効にする')
    ..addFlag('dynamic', negatable: false, help: '動的シミュレーションを有効にする')
    ..addFlag('quiet', negatable: false, help: '送受信を表示しない');
  final ArgResults args;
  final int port;
  try {
    args = parser.parse(argv);
    port = int.parse(args['port'] as String);
  } on FormatException catch (e) {
    stderr.writeln('エラー: ${e.message}');
    stderr.writeln(parser.usage);
    exit(2);
  }
  final quiet = args['quiet'] as bool;

  final core = EmulationCore()..start();
  core.transmission.enabled = args['transmission'] as bool;
  core.simulator.enabled = args['dynamic'] as bool;
  Timer.periodic(const Duration(milliseconds: 200), (_) => core.simulator.tick(0.2));

  final tcp = TcpTransport(port: port);
  ElmSession? session;
  String esc(List<int> b) => String.fromCharCodes(b).replaceAll('\r', r'\r').replaceAll('\n', r'\n');

  tcp.onConnection.listen((state) {
    stdout.writeln('conn $state');
    session?.dispose();
    session = null;
    if (state.startsWith('connected')) {
      final s = core.newSession();
      s.output.listen((b) {
        if (!quiet) stdout.writeln('=> ${esc(b)}');
        tcp.send(b);
      });
      session = s;
    }
  });
  tcp.onReceive.listen((b) {
    if (!quiet) stdout.writeln('<= ${esc(b)}');
    session?.input(b);
  });

  await tcp.start();
  stdout.writeln('listening ${tcp.port}');

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(await applyControl(core, line, disconnect: tcp.disconnect));
  }
  await tcp.stop();
  core.dispose();
  exit(0);
}
