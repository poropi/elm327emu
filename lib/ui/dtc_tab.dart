import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../ecu/ecu_profile.dart';
import '../ecu/pid_table.dart';
import '../util/hex.dart';
import 'common.dart';

class DtcTab extends StatefulWidget {
  const DtcTab({super.key});

  @override
  State<DtcTab> createState() => _DtcTabState();
}

class _DtcTabState extends State<DtcTab> {
  String _ecu = 'engine';

  static String _time(DateTime t) => [
    t.hour,
    t.minute,
    t.second,
  ].map((n) => n.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final e = c.core.ecuByName(_ecu);
    final ff = e.freezeFrame;
    final count = e.confirmedDtcs.length;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EcuSelector(
            ecus: c.core.ecus,
            selected: _ecu,
            onChanged: (n) => setState(() => _ecu = n),
          ),
          const SizedBox(height: 14),
          NoticeBanner(
            warn: count > 0,
            title: count == 0
                ? 'MIL 消灯 · 確定 0 件'
                : 'MIL 点灯中 · 確定 $count 件（0101 の応答に反映）',
          ),
          const SizedBox(height: 14),
          _DtcSection(
            key: ValueKey('confirmed-$_ecu'),
            kind: DtcKind.confirmed,
            title: '確定 DTC（Mode 03）',
            ecu: e,
          ),
          _DtcSection(
            key: ValueKey('pending-$_ecu'),
            kind: DtcKind.pending,
            title: '保留 DTC（Mode 07）',
            ecu: e,
          ),
          _DtcSection(
            key: ValueKey('permanent-$_ecu'),
            kind: DtcKind.permanent,
            title: '永続 DTC（Mode 0A）',
            ecu: e,
            note: 'Mode 04 では消えません（規格どおり）',
          ),
          SectionCard(
            title: 'フリーズフレーム（Mode 02）',
            children: ff == null
                ? const [
                    Text(
                      '保存されていません（確定 DTC を追加すると、その時点の値を保存します）',
                      style: captionStyle,
                    ),
                  ]
                : [
                    Text(
                      '${ff.dtc} を追加した時点の値 · ${_time(ff.capturedAt)}（生バイト）',
                      style: captionStyle,
                    ),
                    for (final pid in ff.pids.keys.toList()..sort())
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text(
                                hex2(pid),
                                style: monoStyle.copyWith(
                                  color: AppColors.teal,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Expanded(child: Text(pidTable[pid]?.label ?? '')),
                            Text(
                              ff.pids[pid]!.map(hex2).join(' '),
                              style: monoStyle,
                            ),
                          ],
                        ),
                      ),
                  ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              key: const Key('dtc-clear'),
              onPressed: () => c.clearDtcs(e),
              child: const Text('DTC を消去（Mode 04 と同じ）'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DtcSection extends StatefulWidget {
  const _DtcSection({
    super.key,
    required this.kind,
    required this.title,
    required this.ecu,
    this.note,
  });

  final DtcKind kind;
  final String title;
  final EcuProfile ecu;
  final String? note;

  @override
  State<_DtcSection> createState() => _DtcSectionState();
}

class _DtcSectionState extends State<_DtcSection> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<String> get _codes => switch (widget.kind) {
    DtcKind.confirmed => widget.ecu.confirmedDtcs,
    DtcKind.pending => widget.ecu.pendingDtcs,
    DtcKind.permanent => widget.ecu.permanentDtcs,
  };

  void _add(EmulatorController c) {
    if (c.addDtc(widget.ecu, widget.kind, _ctrl.text)) {
      _ctrl.clear();
      setState(() => _error = null);
    } else {
      setState(() => _error = '形式が違います（例: P0301）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final name = widget.kind.name;
    return SectionCard(
      title: widget.title,
      children: [
        if (_codes.isEmpty)
          const Text('なし', style: captionStyle)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final code in _codes)
                InputChip(
                  label: Text(code, style: monoStyle),
                  onDeleted: () => c.removeDtc(widget.ecu, widget.kind, code),
                  deleteButtonTooltipMessage: '$code を削除',
                ),
            ],
          ),
        if (widget.note != null) ...[
          const SizedBox(height: 6),
          Text(widget.note!, style: captionStyle),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: Key('dtc-input-$name'),
                controller: _ctrl,
                style: monoStyle,
                decoration: InputDecoration(
                  hintText: '例: P0301',
                  errorText: _error,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _add(c),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: Key('dtc-add-$name'),
              onPressed: () => _add(c),
              child: const Text('追加'),
            ),
          ],
        ),
      ],
    );
  }
}
