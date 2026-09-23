import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';

enum LogFilter { all, elm, can, fault }

const _filterLabels = {
  LogFilter.all: 'すべて',
  LogFilter.elm: 'ELM 文字列',
  LogFilter.can: 'CAN フレーム',
  LogFilter.fault: '障害',
};

bool logMatches(LogFilter f, LogEntry e) => switch (f) {
  LogFilter.all => true,
  LogFilter.elm => e.kind == LogKind.input || e.kind == LogKind.output,
  LogFilter.can => e.kind == LogKind.can,
  LogFilter.fault => e.kind == LogKind.fault,
};

String logLine(LogEntry e) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = e.time;
  final time =
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  const glyph = {
    LogKind.input: '←',
    LogKind.output: '→',
    LogKind.can: '≡',
    LogKind.fault: '!',
    LogKind.info: '·',
  };
  return '$time ${glyph[e.kind]} ${e.text}';
}

class LogTab extends StatefulWidget {
  const LogTab({super.key});

  @override
  State<LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<LogTab> {
  static const _colors = {
    LogKind.input: Color(0xFF7DE0C8),
    LogKind.output: Color(0xFFF2C46D),
    LogKind.can: Color(0xFFC9D4FF),
    LogKind.fault: Color(0xFFFFC9C2),
    LogKind.info: Color(0xFF8A9A94),
  };

  LogFilter _filter = LogFilter.all;
  bool _autoScroll = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final entries = c.log.where((e) => logMatches(_filter, e)).toList();
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in LogFilter.values)
                ChoiceChip(
                  label: Text(_filterLabels[f]!),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.console,
                borderRadius: BorderRadius.circular(14),
              ),
              child: entries.isEmpty
                  ? Text(
                      'ログはありません',
                      style: monoStyle.copyWith(
                        color: AppColors.consoleText,
                        fontSize: 12,
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: entries.length,
                      itemBuilder: (context, i) => Text(
                        logLine(entries[i]),
                        style: monoStyle.copyWith(
                          fontSize: 11.5,
                          height: 1.6,
                          color: _colors[entries[i].kind],
                        ),
                      ),
                    ),
            ),
          ),
          Row(
            children: [
              Checkbox(
                value: _autoScroll,
                onChanged: (v) => setState(() => _autoScroll = v ?? true),
              ),
              const Text('自動スクロール'),
              const Spacer(),
              OutlinedButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: entries.map(logLine).join('\n')),
                ),
                child: const Text('コピー'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: c.clearLog, child: const Text('クリア')),
            ],
          ),
        ],
      ),
    );
  }
}
