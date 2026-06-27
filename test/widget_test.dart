import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:elm327emu/app/emulator_controller.dart';
import 'package:elm327emu/ui/home_page.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('HomePage renders', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => EmulatorController(),  // do NOT call init() in test (no platform channels)
        child: const MaterialApp(home: HomePage()),
      ),
    );
    expect(find.text('ELM327 Emulator'), findsOneWidget);
  });
}
