import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';
import 'vehicle_fields.dart';

class VehicleTab extends StatefulWidget {
  const VehicleTab({super.key});

  @override
  State<VehicleTab> createState() => _VehicleTabState();
}

class _VehicleTabState extends State<VehicleTab> {
  static const _shortCount = 12;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final v = c.vehicle;
    final dynamicMode = c.simulator.enabled;
    final fields = _showAll
        ? vehicleFields
        : vehicleFields.take(_shortCount).toList();
    ValueChanged<double>? edit(void Function(double x) apply) => dynamicMode
        ? null
        : (x) {
            apply(x);
            c.notify();
          };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('動的')),
            ButtonSegment(value: false, label: Text('手動')),
          ],
          selected: {dynamicMode},
          onSelectionChanged: (s) => c.setSimEnabled(s.first),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('イグニッション'),
          subtitle: const Text('OFF にすると全 ECU が応答しない', style: captionStyle),
          value: !c.core.faultConfig.ignitionOff,
          onChanged: (on) => c.updateFaults((f) => f.ignitionOff = !on),
        ),
        SectionCard(
          title: '基本の値',
          children: [
            Text(
              dynamicMode ? '動的モード中は現在値を表示します。手動にすると編集できます' : 'スライダで値を固定できます',
              style: captionStyle,
            ),
            _ValueSlider(
              label: '回転数 (0C)',
              unit: 'rpm',
              value: v.rpm.toDouble(),
              min: 0,
              max: 8000,
              onChanged: edit((x) => v.rpm = x.round()),
            ),
            _ValueSlider(
              label: '車速 (0D)',
              unit: 'km/h',
              value: v.speedKmh,
              min: 0,
              max: 255,
              onChanged: edit((x) => v.speedKmh = x),
            ),
            _ValueSlider(
              label: '水温 (05)',
              unit: '°C',
              value: v.coolantTempC,
              min: -40,
              max: 150,
              onChanged: edit((x) => v.coolantTempC = x),
            ),
            _ValueSlider(
              label: 'スロットル (11)',
              unit: '%',
              value: v.throttlePct,
              min: 0,
              max: 100,
              onChanged: edit((x) => v.throttlePct = x),
            ),
            _ValueSlider(
              label: 'エンジン負荷 (04)',
              unit: '%',
              value: v.engineLoadPct,
              min: 0,
              max: 100,
              onChanged: edit((x) => v.engineLoadPct = x),
            ),
            _ValueSlider(
              label: '電圧 (42 / ATRV)',
              unit: 'V',
              value: v.batteryVoltage,
              min: 8,
              max: 16,
              digits: 1,
              onChanged: edit((x) => v.batteryVoltage = x),
            ),
          ],
        ),
        SectionCard(
          title: 'その他の PID',
          trailing: TextButton(
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(_showAll ? '一部だけ表示' : 'すべて表示'),
          ),
          children: [
            Text(
              '全 ${vehicleFields.length} 項目中 ${fields.length} 項目を表示${dynamicMode ? '' : '（タップで編集）'}',
              style: captionStyle,
            ),
            for (final f in fields)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 28,
                  child: Text(
                    f.pid,
                    style: monoStyle.copyWith(
                      color: AppColors.teal,
                      fontSize: 12,
                    ),
                  ),
                ),
                title: Text(f.label),
                trailing: Text(
                  '${f.format(v)} ${f.unit}'.trim(),
                  style: monoStyle,
                ),
                onTap: dynamicMode
                    ? null
                    : () async {
                        final x = await showDialog<double>(
                          context: context,
                          builder: (_) =>
                              _PidEditDialog(field: f, initial: f.format(v)),
                        );
                        if (x != null) {
                          f.set(c.vehicle, x);
                          c.notify();
                        }
                      },
              ),
          ],
        ),
      ],
    );
  }
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.digits = 0,
  });

  final String label;
  final String unit;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final int digits;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text('${value.toStringAsFixed(digits)} $unit', style: monoStyle),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _PidEditDialog extends StatefulWidget {
  const _PidEditDialog({required this.field, required this.initial});

  final VehicleField field;
  final String initial;

  @override
  State<_PidEditDialog> createState() => _PidEditDialogState();
}

class _PidEditDialogState extends State<_PidEditDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    return AlertDialog(
      title: Text(f.unit.isEmpty ? f.label : '${f.label}（${f.unit}）'),
      content: TextField(
        key: const Key('pid-edit-field'),
        controller: _ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, double.tryParse(_ctrl.text.trim())),
          child: const Text('設定'),
        ),
      ],
    );
  }
}
