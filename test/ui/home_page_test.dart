import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/ui/connection_tab.dart';
import 'package:elm327emu/ui/vehicle_tab.dart';
import '../support/ui_harness.dart';

void main() {
  testWidgets('タイトル・タブ・接続状態', (tester) async {
    await pumpHome(tester);
    expect(find.text('ELM327 Emulator'), findsOneWidget);
    for (final t in ['接続', '車両', 'ログ']) {
      expect(find.descendant(of: find.byType(TabBar), matching: find.text(t)), findsOneWidget);
    }
    expect(find.text('未接続'), findsOneWidget);
  });

  testWidgets('接続タブ: 3 経路・ELM の状態・開始はブリッジへ', (tester) async {
    final (c, b) = await pumpHome(tester);
    expect(find.text('BLE'), findsOneWidget);
    expect(find.text('SPP'), findsOneWidget);
    expect(find.text('TCP（開発用）'), findsOneWidget);
    expect(find.text('A0 · AUTO'), findsOneWidget);
    expect(find.text('ATSH 7DF'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-ble')));
    await tester.pump();
    expect(b.calls, ['startBle:false']);
    expect(find.text('待ち受け中'), findsOneWidget);
    final disconnect = tester.widget<FilledButton>(find.byKey(const Key('disconnect-ble')));
    expect(disconnect.onPressed, isNull); // 接続中でなければ押せない
  });

  testWidgets('車両タブ: 動的と手動・PID の編集・すべて表示・イグニッション', (tester) async {
    final (c, _) = await pumpHome(tester);
    await openTab(tester, '車両');
    await tester.tap(find.text('動的'));
    await tester.pump();
    expect(c.simulator.enabled, isTrue);
    await tester.tap(find.text('手動'));
    await tester.pump();
    expect(c.simulator.enabled, isFalse);

    await tester.tap(find.text('イグニッション'));
    await tester.pump();
    expect(c.core.faultConfig.ignitionOff, isTrue);

    await reveal(tester, find.text('吸気管圧力'), VehicleTab);
    await tester.tap(find.text('吸気管圧力'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pid-edit-field')), '50');
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(c.vehicle.mapKpa, 50);

    expect(find.text('触媒温度'), findsNothing);
    await reveal(tester, find.text('すべて表示'), VehicleTab);
    await tester.tap(find.text('すべて表示'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('触媒温度'), VehicleTab);
    expect(find.text('触媒温度'), findsOneWidget);
  });

  testWidgets('ログタブ: 表示・絞り込み・クリア', (tester) async {
    final (c, _) = await pumpHome(tester);
    c.log
      ..add(LogEntry(DateTime(2026, 9, 23, 14, 2, 11, 201), LogKind.input, 'ATZ'))
      ..add(LogEntry(DateTime(2026, 9, 23, 14, 2, 11, 845), LogKind.can, 'RX 7E8 [8] 06 41 00'));
    c.notify();
    await openTab(tester, 'ログ');
    expect(find.text('14:02:11.201 ← ATZ'), findsOneWidget);
    await tester.tap(find.text('CAN フレーム'));
    await tester.pump();
    expect(find.text('14:02:11.201 ← ATZ'), findsNothing);
    expect(find.text('14:02:11.845 ≡ RX 7E8 [8] 06 41 00'), findsOneWidget);
    await tester.tap(find.text('クリア'));
    await tester.pump();
    expect(c.log, isEmpty);
    expect(find.text('ログはありません'), findsOneWidget);
  });

  testWidgets('接続タブの「ログをすべて見る」でログタブへ', (tester) async {
    await pumpHome(tester);
    await reveal(tester, find.text('ログをすべて見る'), ConnectionTab);
    await tester.tap(find.text('ログをすべて見る'));
    await tester.pumpAndSettle();
    expect(find.text('自動スクロール'), findsOneWidget);
  });

  test('ElmStateGrid.items', () {
    final s = ElmState()
      ..headers = true
      ..craId = 0x7E9;
    final items = ElmStateGrid.items(s);
    expect(items.map((e) => e.$1), ['プロトコル', '送信ヘッダ', '表示', 'CAN 整形', 'タイムアウト', '受信フィルタ']);
    expect(items[2].$2, 'E1 L0 S1 H1 D0');
    expect(items[3].$2, 'CAF1 · NL');
    expect(items[4].$2, 'ST 32 (200ms) · AT1');
    expect(items[5].$2, 'CRA 7E9');
  });
}
