import 'package:test/test.dart';
import 'package:elm327emu/app/control_commands.dart';
import 'package:elm327emu/app/emulation_core.dart';
import 'package:elm327emu/can/fault_injector.dart';

void main() {
  late EmulationCore core;
  setUp(() => core = EmulationCore());

  test('障害の切り替え', () async {
    expect(await applyControl(core, 'ignition off'), 'ok');
    expect(core.faultConfig.ignitionOff, isTrue);
    expect(await applyControl(core, 'ignition on'), 'ok');
    expect(core.faultConfig.ignitionOff, isFalse);
    expect(await applyControl(core, 'silent engine on'), 'ok');
    expect(core.faultConfig.silentEcus, {'engine'});
    expect(await applyControl(core, 'silent engine off'), 'ok');
    expect(core.faultConfig.silentEcus, isEmpty);
    expect(await applyControl(core, 'delay 350'), 'ok');
    expect(core.faultConfig.delayMs, 350);
    expect(await applyControl(core, 'drop 100'), 'ok');
    expect(core.faultConfig.dropPercent, 100);
    expect(await applyControl(core, 'pending on'), 'ok');
    expect(core.faultConfig.responsePending, isTrue);
    expect(await applyControl(core, 'truncate on'), 'ok');
    expect(core.faultConfig.truncateMultiFrame, isTrue);
  });

  test('エラー応答', () async {
    expect(await applyControl(core, 'error canError once'), 'ok');
    expect(core.faultConfig.error, ElmErrorKind.canError);
    expect(core.faultConfig.errorTrigger, ErrorTrigger.once);
    expect(core.faultConfig.errorArmed, isTrue);
    expect(await applyControl(core, 'error bufferFull always'), 'ok');
    expect(core.faultConfig.errorTrigger, ErrorTrigger.always);
    expect(await applyControl(core, 'error off'), 'ok');
    expect(core.faultConfig.errorArmed, isFalse);
    expect(await applyControl(core, 'error nope once'), startsWith('error'));
  });

  test('車両・DTC・ECU・切断', () async {
    expect(await applyControl(core, 'rpm 2150'), 'ok');
    expect(core.vehicle.rpm, 2150);
    expect(await applyControl(core, 'speed 62'), 'ok');
    expect(core.vehicle.speedKmh, 62);
    expect(await applyControl(core, 'dtc add P0420'), 'ok');
    expect(core.engine.confirmedDtcs, ['P0301', 'P0420']);
    expect(await applyControl(core, 'dtc add X1'), startsWith('error'));
    expect(await applyControl(core, 'dtc clear'), 'ok');
    expect(core.engine.confirmedDtcs, isEmpty);
    expect(await applyControl(core, 'transmission on'), 'ok');
    expect(core.transmission.enabled, isTrue);
    var disconnected = false;
    expect(await applyControl(core, 'disconnect', disconnect: () async => disconnected = true), 'ok');
    expect(disconnected, isTrue);
  });

  test('不明・値の形式違い', () async {
    expect(await applyControl(core, 'hello'), startsWith('error'));
    expect(await applyControl(core, 'delay abc'), startsWith('error'));
    expect(await applyControl(core, 'silent brake on'), startsWith('error'));
  });
}
