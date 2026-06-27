import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/emulator_controller.dart';

class ValueControls extends StatelessWidget {
  const ValueControls({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final v = c.vehicle;
    final disabled = c.simulator.enabled;
    Widget slider(String label, double value, double min, double max,
        void Function(double) onChanged) {
      return Row(children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: disabled ? null : onChanged,
          ),
        ),
        SizedBox(width: 56, child: Text(value.toStringAsFixed(0))),
      ]);
    }

    return Column(children: [
      slider('RPM', v.rpm.toDouble(), 600, 7000, (x) {
        v.rpm = x.round();
        c.notify();
      }),
      slider('Speed', v.speedKmh, 0, 200, (x) {
        v.speedKmh = x;
        c.notify();
      }),
      slider('Coolant', v.coolantTempC, 20, 120, (x) {
        v.coolantTempC = x;
        c.notify();
      }),
      slider('Throttle', v.throttlePct, 0, 100, (x) {
        v.throttlePct = x;
        c.notify();
      }),
      slider('Battery', v.batteryVoltage, 8, 15, (x) {
        v.batteryVoltage = x;
        c.notify();
      }),
    ]);
  }
}
