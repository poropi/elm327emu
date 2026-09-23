import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/ui/dtc_tab.dart';
import 'package:elm327emu/ui/ecu_tab.dart';
import 'package:elm327emu/ui/faults_tab.dart';
import '../support/ui_harness.dart';

void main() {
  testWidgets('タブは 6 つ', (tester) async {
    await pumpHome(tester);
    for (final t in ['接続', '車両', 'DTC', 'ECU', '障害', 'ログ']) {
      expect(
        find.descendant(of: find.byType(TabBar), matching: find.text(t)),
        findsOneWidget,
      );
    }
  });

  testWidgets('DTC タブ: 小文字・空白を直して追加・形式違い・削除・消去（Review Focus 5）', (
    tester,
  ) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, 'DTC');
    expect(find.text('MIL 点灯中 · 確定 1 件（0101 の応答に反映）'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('dtc-input-confirmed')),
      ' p0420 ',
    );
    await tester.tap(find.byKey(const Key('dtc-add-confirmed')));
    await tester.pump();
    expect(c.core.engine.confirmedDtcs, ['P0301', 'P0420']);

    await reveal(tester, find.byKey(const Key('dtc-add-pending')), DtcTab);
    await tester.enterText(find.byKey(const Key('dtc-input-pending')), 'X1');
    await tester.tap(find.byKey(const Key('dtc-add-pending')));
    await tester.pump();
    expect(find.text('形式が違います（例: P0301）'), findsOneWidget);
    expect(c.core.engine.pendingDtcs, isEmpty);

    await reveal(tester, find.byTooltip('P0420 を削除'), DtcTab);
    await tester.tap(find.byTooltip('P0420 を削除'));
    await tester.pump();
    expect(c.core.engine.confirmedDtcs, ['P0301']);

    await reveal(tester, find.byKey(const Key('dtc-clear')), DtcTab);
    expect(find.textContaining('P0301 を追加した時点の値'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dtc-clear')));
    await tester.pumpAndSettle();
    expect(c.core.engine.confirmedDtcs, isEmpty);
    expect(find.textContaining('保存されていません'), findsOneWidget);
  });

  testWidgets('ECU タブ: 有効化・Mode 09 の検証と保存・DID の追加', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, 'ECU');
    await tester.tap(find.byKey(const Key('ecu-enable-transmission')));
    await tester.pump();
    expect(c.core.transmission.enabled, isTrue);

    await reveal(tester, find.byKey(const Key('ecu-vin')), EcuTab);
    await tester.enterText(find.byKey(const Key('ecu-vin')), 'SHORT');
    await reveal(tester, find.byKey(const Key('ecu-save')), EcuTab);
    await tester.tap(find.byKey(const Key('ecu-save')));
    await tester.pump();
    expect(find.textContaining('VIN は 17 文字'), findsOneWidget);
    expect(c.core.engine.vin, 'WAUZZZ8K9AA000000');

    await reveal(tester, find.byKey(const Key('ecu-vin')), EcuTab);
    await tester.enterText(
      find.byKey(const Key('ecu-vin')),
      'JT2BF22K1W0123456',
    );
    await reveal(tester, find.byKey(const Key('ecu-save')), EcuTab);
    await tester.tap(find.byKey(const Key('ecu-save')));
    await tester.pump();
    expect(c.core.engine.vin, 'JT2BF22K1W0123456');
    expect(find.text('保存しました'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('did-add')), EcuTab);
    await tester.tap(find.byKey(const Key('did-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('did-id')), 'f1a0');
    await tester.enterText(find.byKey(const Key('did-value')), 'HELLO');
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pumpAndSettle();
    expect(c.core.engine.dids[0xF1A0]!.display, 'HELLO');

    await tester.tap(find.byKey(const Key('did-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('did-id')), 'XYZ');
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pump();
    expect(find.text('DID は 16 進 4 桁'), findsOneWidget);
  });

  testWidgets('ECU タブ: DID 行をタップすると既存の値で編集でき、削除もできる（最終レビュー M6）', (
    tester,
  ) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, 'ECU');
    await reveal(tester, find.text('F191'), EcuTab);
    await tester.tap(find.text('F191'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('did-id')))
          .controller!
          .text,
      'F191',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('did-value')))
          .controller!
          .text,
      '0A 1B 2C 3D',
    );
    expect(find.text('HEX'), findsWidgets);
    await tester.enterText(find.byKey(const Key('did-value')), 'FF 00');
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pumpAndSettle();
    expect(c.core.engine.dids[0xF191]!.bytes, [0xFF, 0x00]);
    expect(c.core.engine.dids[0xF191]!.isAscii, isFalse);

    await reveal(tester, find.text('F190'), EcuTab);
    await tester.tap(find.text('F190'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('did-value')))
          .controller!
          .text,
      'WAUZZZ8K9AA000000',
    );
    await tester.enterText(
      find.byKey(const Key('did-value')),
      'JT2BF22K1W0123456',
    );
    await tester.tap(find.byKey(const Key('did-ok')));
    await tester.pumpAndSettle();
    expect(c.core.engine.dids[0xF190]!.display, 'JT2BF22K1W0123456');

    await reveal(tester, find.byTooltip('F18C を削除'), EcuTab);
    await tester.tap(find.byTooltip('F18C を削除'));
    await tester.pump();
    expect(c.core.engine.dids.containsKey(0xF18C), isFalse);
    expect(find.text('F18C'), findsNothing);
  });

  testWidgets('障害タブ: イグニッション・遅延の注意・エラー・切断ボタン', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, '障害');
    expect(find.text('有効な障害はありません'), findsOneWidget);
    final disconnect = tester.widget<FilledButton>(
      find.byKey(const Key('fault-disconnect')),
    );
    expect(disconnect.onPressed, isNull);

    await tester.tap(find.byKey(const Key('fault-ignition')));
    await tester.pump();
    expect(c.core.faultConfig.ignitionOff, isTrue);
    expect(find.text('有効な障害 1 件'), findsOneWidget);

    c.updateFaults((f) => f.delayMs = 350);
    await tester.pump();
    await reveal(
      tester,
      find.text('ATST 200ms を超えるため、今は NO DATA になります'),
      FaultsTab,
    );

    await reveal(tester, find.byKey(const Key('fault-error-fire')), FaultsTab);
    await tester.tap(find.byKey(const Key('fault-error-fire')));
    await tester.pump();
    expect(c.core.faultConfig.errorArmed, isTrue);
    expect(c.core.faultConfig.error, ElmErrorKind.canError);
    await tester.tap(find.byKey(const Key('fault-error-stop')));
    await tester.pump();
    expect(c.core.faultConfig.errorArmed, isFalse);

    // トランスミッションは既定で無効な ECU → 無応答スイッチは操作できない。
    await reveal(
      tester,
      find.byKey(const Key('fault-silent-transmission')),
      FaultsTab,
    );
    var silentSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('fault-silent-transmission')),
    );
    expect(silentSwitch.onChanged, isNull);
    expect(c.core.transmission.enabled, isFalse);

    c.setEcuEnabled(c.core.transmission, true);
    await tester.pump();
    silentSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('fault-silent-transmission')),
    );
    expect(silentSwitch.onChanged, isNotNull);
  });
}
