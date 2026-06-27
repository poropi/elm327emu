import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/elm327/at_command_handler.dart';

void main() {
  late ElmState state;
  late AtCommandHandler h;
  setUp(() {
    state = ElmState();
    h = AtCommandHandler(state);
  });

  test('ATZ で識別子を返しリセット', () {
    state.echo = false;
    final r = h.handle('ATZ');
    expect(r, 'ELM327 v1.5');
    expect(state.echo, isTrue); // リセットで既定に戻る
  });

  test('ATE0 で echo OFF', () {
    expect(h.handle('ATE0'), 'OK');
    expect(state.echo, isFalse);
  });

  test('ATH1 で headers ON', () {
    expect(h.handle('ATH1'), 'OK');
    expect(state.headers, isTrue);
  });

  test('ATSP6 でプロトコル設定', () {
    expect(h.handle('ATSP6'), 'OK');
    expect(state.protocol, 6);
  });

  test('ATDPN はプロトコル番号', () {
    expect(h.handle('ATDPN'), '6');
  });

  test('ATI は識別子, ATRV は電圧', () {
    expect(h.handle('ATI'), 'ELM327 v1.5');
    expect(h.handle('ATRV'), '12.4V');
  });

  test('非ATは null', () {
    expect(h.handle('010C'), isNull);
  });

  test('未知ATは ?', () {
    expect(h.handle('ATXYZ'), '?');
  });
}
