import 'elm_state.dart';
import 'at_command_handler.dart';
import 'obd_command_handler.dart';
import '../vehicle/vehicle_state.dart';

/// ELM327 の中核。1 コマンド行を完全な応答文字列に変換する。
class Elm327Engine {
  Elm327Engine(this.vehicle) {
    _at = AtCommandHandler(state);
    _obd = ObdCommandHandler(state, vehicle);
  }

  final VehicleState vehicle;
  final ElmState state = ElmState();
  late final AtCommandHandler _at;
  late final ObdCommandHandler _obd;

  String process(String line) {
    final eol = state.linefeed ? '\r\n' : '\r';
    final sb = StringBuffer();

    if (state.echo) {
      sb.write(line);
      sb.write(eol);
    }

    final List<String> responseLines;
    final atResult = _at.handle(line);
    if (atResult != null) {
      responseLines = [atResult];
    } else {
      responseLines = _obd.handle(line);
    }

    for (final l in responseLines) {
      sb.write(l);
      sb.write(eol);
    }
    // 空行 + プロンプト
    sb.write(eol);
    sb.write('>');
    return sb.toString();
  }
}
