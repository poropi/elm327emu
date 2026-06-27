import 'package:test/test.dart';
import 'package:elm327emu/elm327/elm_state.dart';
import 'package:elm327emu/elm327/obd_command_handler.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  late ElmState state;
  late VehicleState v;
  late ObdCommandHandler h;
  setUp(() {
    state = ElmState()..initialized = true;
    v = VehicleState.defaults();
    h = ObdCommandHandler(state, v);
  });

  test('010C RPM (spaces, headers off)', () {
    v.rpm = 1726;
    expect(h.handle('010C'), ['41 0C 1A F8 ']);
  });

  test('010D 車速', () {
    v.speedKmh = 60;
    expect(h.handle('010D'), ['41 0D 3C ']);
  });

  test('0105 水温は +40 オフセット', () {
    v.coolantTempC = 85;
    expect(h.handle('0105'), ['41 05 7D ']); // 85+40=125=0x7D
  });

  test('spaces off で連結', () {
    state.spaces = false;
    v.rpm = 1726;
    expect(h.handle('010C'), ['410C1AF8']);
  });

  test('headers on で 7E8 とPCI付与', () {
    state.headers = true;
    v.rpm = 1726;
    expect(h.handle('010C'), ['7E8 04 41 0C 1A F8 ']);
  });

  test('0100 サポートPIDビットマップ', () {
    expect(h.handle('0100'), ['41 00 18 1B 80 01 ']);
  });

  test('03 でDTC', () {
    v.dtcs = ['P0301'];
    expect(h.handle('03'), ['43 01 03 01 ']);
  });

  test('04 でDTCクリア', () {
    v.dtcs = ['P0301'];
    expect(h.handle('04'), ['44 ']);
    expect(v.dtcs, isEmpty);
  });

  test('0902 VIN はマルチフレーム', () {
    final r = h.handle('0902');
    expect(r.first, matches(RegExp(r'^[0-9A-F]{3}$')));
  });

  test('未対応PIDは NO DATA', () {
    expect(h.handle('01FF'), ['NO DATA']);
  });

  test('初期化前の未対応PIDは SEARCHING... + NO DATA', () {
    state.initialized = false;
    expect(h.handle('01FF'), ['SEARCHING...', 'NO DATA']);
    expect(state.initialized, isTrue);
  });

  test('初期化前は SEARCHING... 先頭', () {
    state.initialized = false;
    v.rpm = 800;
    final r = h.handle('010C');
    expect(r.first, 'SEARCHING...');
    expect(state.initialized, isTrue); // 以後は確立
  });
}
