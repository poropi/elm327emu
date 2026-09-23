import 'dart:math';
import 'package:test/test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ecu/ecu_profile.dart';

void main() {
  test('ElmErrorKind の文言と分類', () {
    expect(ElmErrorKind.canError.text, 'CAN ERROR');
    expect(ElmErrorKind.dataErrorMark.text, '<DATA ERROR');
    expect(ElmErrorKind.rxErrorMark.isMark, isTrue);
    expect(ElmErrorKind.canError.isMark, isFalse);
    expect(ElmErrorKind.lvReset.resetsState, isTrue);
    expect(ElmErrorKind.err94.resetsState, isTrue);
    expect(ElmErrorKind.busError.resetsState, isFalse);
  });

  test('isSilent はイグニッション OFF か ECU 指定', () {
    final cfg = FaultConfig();
    final f = FaultInjector(cfg);
    final e = EcuProfile.engine();
    expect(f.isSilent(e), isFalse);
    cfg.silentEcus.add('engine');
    expect(f.isSilent(e), isTrue);
    cfg.silentEcus.clear();
    cfg.ignitionOff = true;
    expect(f.isSilent(e), isTrue);
  });

  test('rollDrop: 0% は常に false、100% は常に true', () {
    final cfg = FaultConfig();
    final f = FaultInjector(cfg, random: Random(1));
    expect(List.generate(50, (_) => f.rollDrop()).any((x) => x), isFalse);
    cfg.dropPercent = 100;
    expect(List.generate(50, (_) => f.rollDrop()).every((x) => x), isTrue);
  });

  test('takeError: once は 1 回で解除、always は解除しない、未発火は null', () {
    final cfg = FaultConfig()..error = ElmErrorKind.canError;
    final f = FaultInjector(cfg);
    expect(f.takeError(), isNull);
    cfg.errorArmed = true;
    expect(f.takeError(), ElmErrorKind.canError);
    expect(f.takeError(), isNull);
    cfg
      ..errorTrigger = ErrorTrigger.always
      ..errorArmed = true;
    expect(f.takeError(), ElmErrorKind.canError);
    expect(f.takeError(), ElmErrorKind.canError);
  });

  test('extraDelay', () {
    final cfg = FaultConfig()..delayMs = 350;
    expect(FaultInjector(cfg).extraDelay, const Duration(milliseconds: 350));
  });
}
