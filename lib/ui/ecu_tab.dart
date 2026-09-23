import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import '../ecu/ecu_profile.dart';
import '../util/hex.dart';
import 'common.dart';

class EcuTab extends StatefulWidget {
  const EcuTab({super.key});

  @override
  State<EcuTab> createState() => _EcuTabState();
}

class _EcuTabState extends State<EcuTab> {
  String _ecu = 'engine';
  String? _loadedFor;
  final _vin = TextEditingController();
  final _calid = TextEditingController();
  final _cvn = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    for (final c in [_vin, _calid, _cvn, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(EcuProfile e) {
    _vin.text = e.vin;
    _calid.text = e.calid;
    _cvn.text = e.cvn.map(hex2).join();
    _name.text = e.ecuName;
    _error = null;
    _saved = false;
    _loadedFor = e.name;
  }

  void _save(EmulatorController c, EcuProfile e) {
    final err = c.updateEcuInfo(
      e,
      vin: _vin.text.trim(),
      calid: _calid.text,
      cvnHex: _cvn.text.trim(),
      name: _name.text.trim(),
    );
    setState(() {
      _error = err;
      _saved = err == null;
    });
  }

  Widget _field(
    String label,
    TextEditingController ctrl,
    String key, {
    int? maxLength,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('ecu-$key'),
        controller: ctrl,
        maxLength: maxLength,
        style: monoStyle,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EmulatorController>();
    final e = c.core.ecuByName(_ecu);
    if (_loadedFor != e.name) _load(e);
    final dids = e.dids.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: '応答する ECU',
          children: [
            for (final p in c.core.ecus)
              SwitchListTile(
                key: Key('ecu-enable-${p.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  p.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '11bit ${hexN(p.requestId11, 3)} → ${hexN(p.responseId11, 3)}　'
                  '29bit ${hexN(p.requestId29, 8)} → ${hexN(p.responseId29For(0xF1), 8)}',
                  style: monoStyle.copyWith(
                    fontSize: 12,
                    color: AppColors.caption,
                  ),
                ),
                value: p.enabled,
                onChanged: (v) => c.setEcuEnabled(p, v),
              ),
          ],
        ),
        EcuSelector(
          ecus: c.core.ecus,
          selected: _ecu,
          onChanged: (n) => setState(() => _ecu = n),
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: '車両情報（Mode 09）',
          children: [
            _field('VIN (02)', _vin, 'vin', maxLength: 17),
            _field('CALID (04)', _calid, 'calid', maxLength: 16),
            _field('CVN (06)', _cvn, 'cvn', hint: '16 進 8 桁'),
            _field('ECU 名 (0A)', _name, 'name', maxLength: 20),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 13),
              ),
            if (_saved) const Text('保存しました', style: captionStyle),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('ecu-save'),
                onPressed: () => _save(c, e),
                child: const Text('保存'),
              ),
            ),
          ],
        ),
        SectionCard(
          title: 'Mode 22 の DID',
          children: [
            for (final entry in dids)
              Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      hexN(entry.key, 4),
                      style: monoStyle.copyWith(color: AppColors.teal),
                    ),
                  ),
                  SizedBox(
                    width: 54,
                    child: Text(
                      entry.value.isAscii ? 'ASCII' : 'HEX',
                      style: captionStyle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value.display,
                      style: monoStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '${hexN(entry.key, 4)} を削除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => c.removeDid(e, entry.key),
                  ),
                ],
              ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '未登録の DID には 7F 22 31 を返します',
                    style: captionStyle,
                  ),
                ),
                FilledButton.tonal(
                  key: const Key('did-add'),
                  onPressed: () async {
                    final r = await showDialog<(int, DidValue)>(
                      context: context,
                      builder: (_) => const _DidDialog(),
                    );
                    if (r != null) c.setDid(e, r.$1, r.$2);
                  },
                  child: const Text('DID を追加'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _DidDialog extends StatefulWidget {
  const _DidDialog();

  @override
  State<_DidDialog> createState() => _DidDialogState();
}

class _DidDialogState extends State<_DidDialog> {
  static final _didPattern = RegExp(r'^[0-9A-F]{4}$');
  static final _printable = RegExp(r'^[\x20-\x7E]+$');

  final _did = TextEditingController();
  final _value = TextEditingController();
  bool _ascii = true;
  String? _error;

  @override
  void dispose() {
    _did.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final didText = _did.text.trim().toUpperCase();
    if (!_didPattern.hasMatch(didText)) {
      setState(() => _error = 'DID は 16 進 4 桁');
      return;
    }
    final DidValue value;
    if (_ascii) {
      if (!_printable.hasMatch(_value.text)) {
        setState(() => _error = '値は表示可能な ASCII 1 文字以上');
        return;
      }
      value = DidValue.ascii(_value.text);
    } else {
      final bytes = parseHexBytes(_value.text.replaceAll(' ', ''));
      if (bytes == null) {
        setState(() => _error = '値は 16 進（例 0A 1B）');
        return;
      }
      value = DidValue.hex(bytes);
    }
    Navigator.pop(context, (int.parse(didText, radix: 16), value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DID を追加'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('did-id'),
            controller: _did,
            decoration: const InputDecoration(labelText: 'DID（16 進 4 桁）'),
          ),
          Row(
            children: [
              const Text('形式'),
              const SizedBox(width: 12),
              DropdownButton<bool>(
                value: _ascii,
                items: const [
                  DropdownMenuItem(value: true, child: Text('ASCII')),
                  DropdownMenuItem(value: false, child: Text('HEX')),
                ],
                onChanged: (v) => setState(() => _ascii = v ?? true),
              ),
            ],
          ),
          TextField(
            key: const Key('did-value'),
            controller: _value,
            decoration: InputDecoration(
              labelText: _ascii ? '値（ASCII）' : '値（16 進、例 0A 1B）',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 13),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('did-ok'),
          onPressed: _submit,
          child: const Text('追加'),
        ),
      ],
    );
  }
}
