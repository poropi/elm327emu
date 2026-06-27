import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app/emulator_controller.dart';
import 'ui/home_page.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => EmulatorController()..init(),
      child: const Elm327App(),
    ),
  );
}

class Elm327App extends StatelessWidget {
  const Elm327App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ELM327 Emulator',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
