import '../can/fault_injector.dart';
import '../ecu/dtc.dart';
import 'emulation_core.dart';

/// CLI（bin/elm327_tcp.dart）が標準入力から受ける制御コマンド。戻り値は 'ok' か 'error <理由>'。
///
/// ```text
/// ignition on|off / silent <engine|transmission> on|off / delay <ms> / drop <pct>
/// pending on|off / truncate on|off / error <種類> once|always / error off
/// transmission on|off / rpm <n> / speed <n> / dtc add <code> / dtc clear / disconnect
/// ```
Future<String> applyControl(EmulationCore core, String line,
    {Future<void> Function()? disconnect}) async {
  final f = core.faultConfig;
  final parts = line.trim().split(RegExp(r'\s+'));
  bool? onOff(String s) => s == 'on' ? true : (s == 'off' ? false : null);
  String err(String why) => 'error $why';

  switch (parts) {
    case ['ignition', final v] when onOff(v) != null:
      f.ignitionOff = !onOff(v)!;
    case ['silent', final ecu, final v] when onOff(v) != null:
      if (!core.ecus.any((e) => e.name == ecu)) return err('unknown ecu: $ecu');
      onOff(v)! ? f.silentEcus.add(ecu) : f.silentEcus.remove(ecu);
    case ['delay', final ms]:
      final n = int.tryParse(ms);
      if (n == null || n < 0) return err('delay must be >= 0');
      f.delayMs = n;
    case ['drop', final pct]:
      final n = int.tryParse(pct);
      if (n == null || n < 0 || n > 100) return err('drop must be 0..100');
      f.dropPercent = n;
    case ['pending', final v] when onOff(v) != null:
      f.responsePending = onOff(v)!;
    case ['truncate', final v] when onOff(v) != null:
      f.truncateMultiFrame = onOff(v)!;
    case ['error', 'off']:
      f.errorArmed = false;
    case ['error', final kind, final trigger] when trigger == 'once' || trigger == 'always':
      final k = ElmErrorKind.values.where((e) => e.name == kind).firstOrNull;
      if (k == null) return err('unknown error kind: $kind');
      f
        ..error = k
        ..errorTrigger = trigger == 'once' ? ErrorTrigger.once : ErrorTrigger.always
        ..errorArmed = true;
    case ['transmission', final v] when onOff(v) != null:
      core.transmission.enabled = onOff(v)!;
    case ['rpm', final n] when int.tryParse(n) != null:
      core.vehicle.rpm = int.parse(n);
    case ['speed', final n] when double.tryParse(n) != null:
      core.vehicle.speedKmh = double.parse(n);
    case ['dtc', 'add', final code]:
      if (!isValidDtc(code)) return err('invalid dtc: $code');
      core.obd.addConfirmedDtc(core.engine, code);
    case ['dtc', 'clear']:
      core.obd.clearDtcs(core.engine);
    case ['disconnect']:
      await disconnect?.call();
    default:
      return err('unknown command: ${line.trim()}');
  }
  return 'ok';
}
