import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';
import '../transport/transport.dart';
import 'value_controls.dart';
import 'dtc_editor.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final hasSpp = c.caps.contains(TransportType.spp);
    return Scaffold(
      appBar: AppBar(title: const Text('ELM327 Emulator')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: c.startBle,
            icon: const Icon(Icons.bluetooth),
            label: const Text('Start BLE'),
          ),
          OutlinedButton(onPressed: c.stopBle, child: const Text('Stop BLE')),
          if (hasSpp)
            FilledButton.icon(
              onPressed: c.startSpp,
              icon: const Icon(Icons.settings_bluetooth),
              label: const Text('Start SPP'),
            ),
          if (hasSpp)
            OutlinedButton(onPressed: c.stopSpp, child: const Text('Stop SPP')),
        ]),
        const SizedBox(height: 8),
        Text('接続: ${c.connState.entries.map((e) => '${e.key.wire}=${e.value}').join(' / ')}'),
        Row(children: [
          const Text('BLE profile:'),
          const SizedBox(width: 8),
          DropdownButton<bool>(
            value: c.useFff0,
            items: const [
              DropdownMenuItem(value: false, child: Text('FFE0/FFE1')),
              DropdownMenuItem(value: true, child: Text('FFF0/FFF1/FFF2')),
            ],
            onChanged: (v) => c.setBleProfile(v ?? false),
          ),
        ]),
        SwitchListTile(
          title: const Text('動的シミュレーション'),
          value: c.simulator.enabled,
          onChanged: c.setSimEnabled,
        ),
        const Divider(),
        const ValueControls(),
        const Divider(),
        const DtcEditor(),
        const Divider(),
        const Text('ログ', style: TextStyle(fontWeight: FontWeight.bold)),
        Container(
          height: 240,
          color: Colors.black12,
          padding: const EdgeInsets.all(8),
          child: ListView(
            reverse: true,
            children: c.log.reversed
                .map((l) => Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)))
                .toList(),
          ),
        ),
      ]),
    );
  }
}
