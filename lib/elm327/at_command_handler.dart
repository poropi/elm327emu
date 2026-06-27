import 'elm_state.dart';

/// AT コマンドを処理する。AT 以外は null を返す。
class AtCommandHandler {
  AtCommandHandler(this.state);
  final ElmState state;

  static const _id = 'ELM327 v1.5';

  String? handle(String cmd) {
    final c = cmd.toUpperCase().replaceAll(' ', '');
    if (!c.startsWith('AT')) return null;
    final body = c.substring(2);

    if (body == 'Z' || body == 'WS' || body == 'D') {
      state.reset();
      return _id;
    }
    if (body == 'I') return _id;
    if (body == '@1' || body == '@2') return 'ELM327 OBD EMULATOR';
    if (body == 'RV') return '12.4V';
    if (body == 'DPN') return state.protocol.toRadixString(16).toUpperCase();
    if (body == 'DP') return 'ISO 15765-4 (CAN 11/500)';

    if (body.startsWith('E')) return _setBool(body, (v) => state.echo = v);
    if (body.startsWith('L')) return _setBool(body, (v) => state.linefeed = v);
    if (body.startsWith('H')) return _setBool(body, (v) => state.headers = v);
    if (body.startsWith('SP')) {
      final p = body.substring(2).replaceFirst('A', '');
      final n = int.tryParse(p, radix: 16);
      if (n != null) state.protocol = n == 0 ? 6 : n;
      return 'OK';
    }
    if (body.startsWith('S') && body.length == 2) {
      return _setBool(body, (v) => state.spaces = v);
    }
    // 受理するが状態を持たない系（タイミング等）は OK
    if (body.startsWith('ST') ||
        body.startsWith('AT') ||
        body.startsWith('AL') ||
        body.startsWith('CAF') ||
        body.startsWith('M') ||
        body.startsWith('CRA') ||
        body.startsWith('FC')) {
      return 'OK';
    }
    return '?';
  }

  String _setBool(String body, void Function(bool) apply) {
    if (body.endsWith('1')) {
      apply(true);
      return 'OK';
    }
    if (body.endsWith('0')) {
      apply(false);
      return 'OK';
    }
    return '?';
  }
}
