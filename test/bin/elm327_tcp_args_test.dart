import 'dart:io';

import 'package:test/test.dart';

/// bin/elm327_tcp.dart を実プロセスとして起動し、引数エラー時の終了コードと出力を確かめる。
void main() {
  test('--port が数字でないと 1 行のエラーと使い方を出して終了コード 2', () async {
    final result = await Process.run('dart', ['run', 'bin/elm327_tcp.dart', '--port', 'abc']);
    expect(result.exitCode, 2);
    expect(result.stderr.toString(), contains('エラー'));
    expect(result.stderr.toString(), contains('--port'));
    expect(result.stderr.toString(), isNot(contains('#0')));
    expect(result.stdout.toString(), isEmpty);
  });

  test('未知の引数だと 1 行のエラーと使い方を出して終了コード 2', () async {
    final result = await Process.run('dart', ['run', 'bin/elm327_tcp.dart', '--bogus']);
    expect(result.exitCode, 2);
    expect(result.stderr.toString(), contains('エラー'));
    expect(result.stderr.toString(), isNot(contains('#0')));
  });
}
