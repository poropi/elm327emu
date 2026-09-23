import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../elm327/elm_state.dart';
import '../transport/transport.dart';
import '../util/hex.dart';
import 'common.dart';

class ConnectionTab extends StatelessWidget {
  const ConnectionTab({super.key, required this.onShowLog});

  final VoidCallback onShowLog;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final talk = c.log
        .where((e) => e.kind == LogKind.input || e.kind == LogKind.output)
        .toList();
    final recent = talk.length > 4 ? talk.sublist(talk.length - 4) : talk;
    final consoleText = monoStyle.copyWith(
      color: AppColors.consoleText,
      fontSize: 12,
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Bluetooth',
          children: [
            _TransportRow(
              id: 'ble',
              label: 'BLE',
              note: '広告名 OBDII',
              status: c.statusText(TransportType.ble),
              onStart: c.startBle,
              onStop: c.stopBle,
              onDisconnect: () => c.disconnect(TransportType.ble),
            ),
            Row(
              children: [
                const Expanded(child: Text('BLE プロファイル')),
                DropdownButton<bool>(
                  value: c.useFff0,
                  items: const [
                    DropdownMenuItem(value: false, child: Text('FFE0 / FFE1')),
                    DropdownMenuItem(
                      value: true,
                      child: Text('FFF0 / FFF1 / FFF2'),
                    ),
                  ],
                  onChanged: (v) => c.setBleProfile(v ?? false),
                ),
              ],
            ),
            if (c.caps.contains(TransportType.spp)) ...[
              const Divider(height: 24),
              _TransportRow(
                id: 'spp',
                label: 'SPP',
                note: 'Android のみ · UUID 1101',
                status: c.statusText(TransportType.spp),
                onStart: c.startSpp,
                onStop: c.stopSpp,
                onDisconnect: () => c.disconnect(TransportType.spp),
              ),
            ],
            if (c.caps.contains(TransportType.tcp)) ...[
              const Divider(height: 24),
              _TransportRow(
                id: 'tcp',
                label: 'TCP（開発用）',
                note: 'macOS のみ · 127.0.0.1:${c.tcp.port}',
                status: c.statusText(TransportType.tcp),
                onStart: c.startTcp,
                onStop: c.stopTcp,
                onDisconnect: () => c.disconnect(TransportType.tcp),
              ),
            ],
          ],
        ),
        SectionCard(
          title: 'ELM の現在の状態',
          children: [ElmStateGrid(state: c.displayState)],
        ),
        SectionCard(
          title: '最近のやりとり',
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.console,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (recent.isEmpty) Text('まだありません', style: consoleText),
                  for (final e in recent)
                    Text(
                      '${e.kind == LogKind.input ? '←' : '→'} ${e.text}',
                      style: consoleText,
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onShowLog,
                child: const Text('ログをすべて見る'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.id,
    required this.label,
    required this.note,
    required this.status,
    required this.onStart,
    required this.onStop,
    required this.onDisconnect,
  });

  final String id;
  final String label;
  final String note;
  final String status;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = status.startsWith('接続中');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 14)),
                  Text(note, style: captionStyle),
                ],
              ),
            ),
            Chip(
              label: Text(status, style: const TextStyle(fontSize: 12)),
              backgroundColor: connected
                  ? AppColors.tealLight
                  : AppColors.neutralBg,
              side: BorderSide.none,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: Key('start-$id'),
              onPressed: onStart,
              child: const Text('開始'),
            ),
            OutlinedButton(
              key: Key('stop-$id'),
              onPressed: onStop,
              child: const Text('停止'),
            ),
            FilledButton(
              key: Key('disconnect-$id'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: connected ? onDisconnect : null,
              child: const Text('切断'),
            ),
          ],
        ),
      ],
    );
  }
}

/// ELM の AT 設定を 2 列で並べる。
class ElmStateGrid extends StatelessWidget {
  const ElmStateGrid({super.key, required this.state});

  final ElmState state;

  static List<(String, String)> items(ElmState s) {
    String b(bool v) => v ? '1' : '0';
    final width = s.is29bit ? 8 : 3;
    final cra = s.craId;
    final mask = s.maskId;
    final ra = s.receiveAddress;
    final filter = cra != null
        ? 'CRA ${hexN(cra, width)}'
        : mask != null
        ? 'CF ${hexN(s.filterId ?? 0, width)} / CM ${hexN(mask, width)}'
        : ra != null
        ? 'RA ${hex2(ra)}'
        : 'なし';
    return [
      ('プロトコル', '${s.describeProtocolNumber()} · ${s.describeProtocol()}'),
      ('送信ヘッダ', 'ATSH ${hexN(s.txId, width)}'),
      (
        '表示',
        'E${b(s.echo)} L${b(s.linefeed)} S${b(s.spaces)} H${b(s.headers)} D${b(s.dlc)}',
      ),
      ('CAN 整形', 'CAF${b(s.caf)} · ${s.allowLong ? 'AL' : 'NL'}'),
      (
        'タイムアウト',
        'ST ${hex2(s.timeoutHex)} (${s.timeout.inMilliseconds}ms) · AT${s.timing.index}',
      ),
      ('受信フィルタ', filter),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (k, v) in items(state))
              Container(
                width: w,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.tile,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(k, style: captionStyle.copyWith(fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(v, style: monoStyle),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
