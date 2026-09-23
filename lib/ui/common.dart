import 'package:flutter/material.dart';

import '../ecu/ecu_profile.dart';
import '../util/hex.dart';

/// 画面案（https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa ）の色。
class AppColors {
  static const teal = Color(0xFF0F5F56);
  static const tealLight = Color(0xFFD5EEE9);
  static const tabInactive = Color(0xFFD3ECE7);
  static const console = Color(0xFF16201D);
  static const consoleText = Color(0xFFDDE7E3);
  static const warnBg = Color(0xFFFCEBC9);
  static const warnFg = Color(0xFF6B4500);
  static const neutralBg = Color(0xFFECEEEC);
  static const tile = Color(0xFFF4F5F2);
  static const danger = Color(0xFFB3261E);
  static const caption = Color(0xFF4A524E);
}

const monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 13);
const captionStyle = TextStyle(fontSize: 12, color: AppColors.caption);

/// 角丸・枠線・見出し付きのカード。
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFD9DDD9)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            ?trailing,
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}

/// 画面上部の注意帯（MIL・有効な障害など）。
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.title, this.lines = const [], this.warn = true});

  final String title;
  final List<String> lines;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final fg = warn ? AppColors.warnFg : AppColors.caption;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: warn ? AppColors.warnBg : AppColors.neutralBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: fg)),
        for (final l in lines) Text(l, style: TextStyle(fontSize: 13, color: fg)),
      ]),
    );
  }
}

/// ECU の切り替え（DTC タブと ECU タブで共通）。
class EcuSelector extends StatelessWidget {
  const EcuSelector({super.key, required this.ecus, required this.selected, required this.onChanged});

  final List<EcuProfile> ecus;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        for (final e in ecus)
          ButtonSegment(
            value: e.name,
            label: Text(e.enabled ? '${e.label} ${hexN(e.responseId11, 3)}' : '${e.label}（無効）'),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
