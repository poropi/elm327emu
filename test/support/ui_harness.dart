import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/transport/transport.dart';
import 'package:elm327emu/ui/home_page.dart';
import 'fake_bridge.dart';

/// スマホ幅（420×900）で HomePage を表示する。init() は呼ばない（タイマーを動かさない）。
Future<(EmulatorController, FakeTransportBridge)> pumpHome(
  WidgetTester tester,
) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final bridge = FakeTransportBridge();
  final c = EmulatorController(bridge: bridge, tcpAvailable: true)
    ..caps = [TransportType.ble, TransportType.spp, TransportType.tcp];
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: c,
      child: const MaterialApp(home: HomePage()),
    ),
  );
  return (c, bridge);
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// タブの中の縦スクロールを動かして [target] を画面に出す。
Future<void> reveal(WidgetTester tester, Finder target, Type tab) async {
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find
        .descendant(of: find.byType(tab), matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
}
