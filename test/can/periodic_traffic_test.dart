import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/fault_injector.dart';
import 'package:elm327emu/can/periodic_traffic.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';
import 'package:elm327emu/vehicle/vehicle_state.dart';

void main() {
  test('1 秒で 0C9 が 50 回、3E9 が 10 回、4C1 が 1 回', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final cfg = FaultConfig();
      final traffic = PeriodicTraffic(bus, VehicleState.defaults(), FaultInjector(cfg))..start();
      final ids = <int>[];
      bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(seconds: 1));
      expect(ids.where((i) => i == 0x0C9).length, 50);
      expect(ids.where((i) => i == 0x3E9).length, 10);
      expect(ids.where((i) => i == 0x4C1).length, 1);
      traffic.stop();
      ids.clear();
      async.elapse(const Duration(seconds: 1));
      expect(ids, isEmpty);
    });
  });

  test('中身は車両状態から作る', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final v = VehicleState.defaults()
        ..rpm = 2150
        ..speedKmh = 62
        ..throttlePct = 50;
      PeriodicTraffic(bus, v, FaultInjector(FaultConfig())).start();
      final frames = <CanFrame>[];
      bus.listen((e) => frames.add(e.frame));
      async.elapse(const Duration(seconds: 1));
      expect(frames.firstWhere((f) => f.id == 0x0C9).data, [0x21, 0x98, 0x80, 0, 0, 0, 0, 0]);
      expect(frames.firstWhere((f) => f.id == 0x3E9).data, [0x18, 0x38, 0, 0, 0, 0, 0, 0]);
      expect(frames.firstWhere((f) => f.id == 0x4C1).data, [0x7D, 0x82, 0, 0, 0, 0, 0, 0]);
    });
  });

  test('イグニッション OFF 中は流さない', () {
    fakeAsync((async) {
      final bus = VirtualCanBus();
      final cfg = FaultConfig()..ignitionOff = true;
      PeriodicTraffic(bus, VehicleState.defaults(), FaultInjector(cfg)).start();
      final ids = <int>[];
      bus.listen((e) => ids.add(e.frame.id));
      async.elapse(const Duration(seconds: 1));
      expect(ids, isEmpty);
    });
  });
}
