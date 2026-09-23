import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../can/fault_injector.dart';
import '../util/hex.dart';
import 'common.dart';

class FaultsTab extends StatelessWidget {
  const FaultsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final f = c.core.faultConfig;
    final active = c.activeFaultDescriptions();
    final timeoutMs = c.displayState.timeout.inMilliseconds;
    final engineLatency = c.core.engine.baseLatency.inMilliseconds;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        NoticeBanner(
          warn: active.isNotEmpty,
          title: active.isEmpty ? '有効な障害はありません' : '有効な障害 ${active.length} 件',
          lines: active,
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: '接続',
          children: [
            SwitchListTile(
              key: const Key('fault-ignition'),
              contentPadding: EdgeInsets.zero,
              title: const Text('イグニッション OFF'),
              subtitle: const Text(
                'UNABLE TO CONNECT / CAN ERROR',
                style: captionStyle,
              ),
              value: f.ignitionOff,
              onChanged: (v) => c.updateFaults((x) => x.ignitionOff = v),
            ),
            const Divider(),
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('接続を切る'),
                      Text('macOS は疑似的な切断（サービスの再登録）', style: captionStyle),
                    ],
                  ),
                ),
                FilledButton(
                  key: const Key('fault-disconnect'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  onPressed: c.connectedTransports.isEmpty
                      ? null
                      : c.disconnectAll,
                  child: const Text('今すぐ切断'),
                ),
              ],
            ),
          ],
        ),
        SectionCard(
          title: 'ECU の無応答',
          children: [
            for (final p in c.core.ecus)
              SwitchListTile(
                key: Key('fault-silent-${p.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text('${p.label} ${hexN(p.responseId11, 3)}'),
                subtitle: p.enabled
                    ? null
                    : const Text('ECU が無効のため対象外', style: captionStyle),
                value: f.silentEcus.contains(p.name),
                onChanged: p.enabled
                    ? (v) => c.updateFaults(
                        (x) => v
                            ? x.silentEcus.add(p.name)
                            : x.silentEcus.remove(p.name),
                      )
                    : null,
              ),
          ],
        ),
        SectionCard(
          title: 'タイミングと欠落',
          children: [
            _FaultSlider(
              label: '応答の遅延',
              unit: 'ms',
              value: f.delayMs,
              max: 2000,
              divisions: 40,
              note: f.delayMs + engineLatency > timeoutMs
                  ? 'ATST ${timeoutMs}ms を超えるため、今は NO DATA になります'
                  : null,
              onCommit: (v) => c.updateFaults((x) => x.delayMs = v),
            ),
            _FaultSlider(
              label: 'ランダムな欠落',
              unit: '%',
              value: f.dropPercent,
              max: 100,
              divisions: 20,
              onCommit: (v) => c.updateFaults((x) => x.dropPercent = v),
            ),
            SwitchListTile(
              key: const Key('fault-pending'),
              contentPadding: EdgeInsets.zero,
              title: const Text('応答保留（7F xx 78）'),
              subtitle: const Text(
                'ECU 指定の要求に 7F xx 78 を返し、1 秒後に本応答',
                style: captionStyle,
              ),
              value: f.responsePending,
              onChanged: (v) => c.updateFaults((x) => x.responsePending = v),
            ),
            SwitchListTile(
              key: const Key('fault-truncate'),
              contentPadding: EdgeInsets.zero,
              title: const Text('複数フレームの途中欠落'),
              subtitle: const Text('最初のフレームだけ返す', style: captionStyle),
              value: f.truncateMultiFrame,
              onChanged: (v) => c.updateFaults((x) => x.truncateMultiFrame = v),
            ),
          ],
        ),
        SectionCard(
          title: 'エラー応答',
          children: [
            Row(
              children: [
                const Text('返すエラー'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<ElmErrorKind>(
                    isExpanded: true,
                    value: f.error ?? ElmErrorKind.canError,
                    items: [
                      for (final k in ElmErrorKind.values)
                        DropdownMenuItem(
                          value: k,
                          child: Text(k.text, style: monoStyle),
                        ),
                    ],
                    onChanged: (k) => c.updateFaults((x) => x.error = k),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<ErrorTrigger>(
              segments: const [
                ButtonSegment(value: ErrorTrigger.once, label: Text('次の1回だけ')),
                ButtonSegment(value: ErrorTrigger.always, label: Text('常に')),
              ],
              selected: {f.errorTrigger},
              onSelectionChanged: (s) =>
                  c.updateFaults((x) => x.errorTrigger = s.first),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (f.errorArmed)
                  OutlinedButton(
                    key: const Key('fault-error-stop'),
                    onPressed: () =>
                        c.updateFaults((x) => x.errorArmed = false),
                    child: const Text('止める'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('fault-error-fire'),
                  onPressed: () => c.updateFaults((x) {
                    x.error ??= ElmErrorKind.canError;
                    x.errorArmed = true;
                  }),
                  child: const Text('エラーを起こす'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// ドラッグ中は表示だけ変え、離したときに設定へ反映する（ログが溢れないように）。
class _FaultSlider extends StatefulWidget {
  const _FaultSlider({
    required this.label,
    required this.unit,
    required this.value,
    required this.max,
    required this.divisions,
    required this.onCommit,
    this.note,
  });

  final String label;
  final String unit;
  final int value;
  final int max;
  final int divisions;
  final ValueChanged<int> onCommit;
  final String? note;

  @override
  State<_FaultSlider> createState() => _FaultSliderState();
}

class _FaultSliderState extends State<_FaultSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final shown = (_dragging ?? widget.value.toDouble()).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text('$shown ${widget.unit}', style: monoStyle),
          ],
        ),
        Slider(
          value: shown.toDouble(),
          max: widget.max.toDouble(),
          divisions: widget.divisions,
          label: '$shown${widget.unit}',
          onChanged: (x) => setState(() => _dragging = x),
          onChangeEnd: (x) {
            setState(() => _dragging = null);
            widget.onCommit(x.round());
          },
        ),
        if (widget.note != null) Text(widget.note!, style: captionStyle),
      ],
    );
  }
}
