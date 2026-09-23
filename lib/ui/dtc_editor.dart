import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';

class DtcEditor extends StatefulWidget {
  const DtcEditor({super.key});
  @override
  State<DtcEditor> createState() => _DtcEditorState();
}

class _DtcEditorState extends State<DtcEditor> {
  final _ctrl = TextEditingController();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('DTCs', style: TextStyle(fontWeight: FontWeight.bold)),
      Wrap(
        spacing: 8,
        children: c.core.engine.confirmedDtcs
            .map((d) => Chip(
                  label: Text(d),
                  onDeleted: () => c.removeDtc(c.core.engine, DtcKind.confirmed, d),
                ))
            .toList(),
      ),
      Row(children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: _ctrl,
            decoration: const InputDecoration(hintText: 'P0301'),
          ),
        ),
        TextButton(
          onPressed: () {
            final t = _ctrl.text.trim().toUpperCase();
            if (c.addDtc(c.core.engine, DtcKind.confirmed, t)) _ctrl.clear();
          },
          child: const Text('追加'),
        ),
      ]),
    ]);
  }
}
