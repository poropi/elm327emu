import 'package:test/test.dart';
import 'package:elm327emu/can/can_frame.dart';
import 'package:elm327emu/can/virtual_can_bus.dart';

class _Recorder implements BusNode {
  final frames = <CanFrame>[];
  @override
  void onFrame(CanFrame frame) => frames.add(frame);
}

void main() {
  group('CanFrame', () {
    test('9 バイト以上は拒否', () {
      expect(() => CanFrame(0x7DF, List.filled(9, 0)), throwsArgumentError);
    });

    test('11bit で 0x800 以上は拒否、29bit は通る', () {
      expect(() => CanFrame(0x800, [0]), throwsArgumentError);
      expect(CanFrame(0x18DAF110, [0], extended: true).id, 0x18DAF110);
    });

    test('toString', () {
      expect(CanFrame(0x7E8, [0x04, 0x41]).toString(), '7E8 [2] 04 41');
      expect(CanFrame(0x18DAF110, [0x01], extended: true).toString(),
          '18DAF110 [1] 01');
    });

    test('== はデータまで比べる', () {
      expect(CanFrame(0x7E8, [1, 2]), CanFrame(0x7E8, [1, 2]));
      expect(CanFrame(0x7E8, [1, 2]) == CanFrame(0x7E8, [1, 3]), isFalse);
    });
  });

  group('VirtualCanBus', () {
    test('送信元以外のノードに配り、リスナーには全部流す', () {
      final bus = VirtualCanBus();
      final a = _Recorder();
      final b = _Recorder();
      bus
        ..attach(a)
        ..attach(b);
      final seen = <BusEvent>[];
      bus.listen(seen.add);
      final f = CanFrame(0x7DF, [0x02, 0x01, 0x0C]);
      bus.transmit(f, sender: a);
      expect(a.frames, isEmpty);
      expect(b.frames, [f]);
      expect(seen.single.frame, f);
      expect(seen.single.sender, same(a));
    });

    test('detach したノードと解除したリスナーには配らない', () {
      final bus = VirtualCanBus();
      final a = _Recorder();
      bus.attach(a);
      bus.detach(a);
      final seen = <BusEvent>[];
      final cancel = bus.listen(seen.add);
      cancel();
      bus.transmit(CanFrame(0x7DF, [0]));
      expect(a.frames, isEmpty);
      expect(seen, isEmpty);
    });

    test('リスナーの中から transmit しても配られる（再入）', () {
      final bus = VirtualCanBus();
      final node = _Recorder();
      bus.attach(node);
      bus.listen((e) {
        if (e.frame.id == 0x7E8) bus.transmit(CanFrame(0x7E0, [0x30]));
      });
      bus.transmit(CanFrame(0x7E8, [0x10]), sender: Object());
      expect(node.frames.map((f) => f.id), [0x7E0, 0x7E8]);
    });
  });
}
