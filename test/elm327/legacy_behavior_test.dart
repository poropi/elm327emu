import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import '../support/elm_harness.dart';

void t(String name, void Function(ElmHarness h) body) {
  test(name, () => fakeAsync((async) => body(ElmHarness(async))));
}

void main() {
  group('旧 elm327_engine_test', () {
    t('ATZ: エコー + 識別子 + プロンプト（旧: 空行なし）', (h) {
      expect(h.send('ATZ'), 'ATZ\r\r\rELM327 v1.5\r\r>');
    });
    t('echo OFF 後はエコーしない', (h) {
      h.send('ATE0');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
    });
    t('OBD 応答にプロンプト', (h) {
      h.quiet();
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '41 0C 1A F8 \r\r>');
    });
    t('linefeed ON は CRLF', (h) {
      h.send('ATE0');
      h.send('ATL1');
      expect(h.send('ATI'), 'ELM327 v1.5\r\n\r\n>');
    });
  });

  group('旧 at_command_handler_test', () {
    t('ATZ でリセット（エコーが戻る）', (h) {
      h.send('ATE0');
      h.send('ATZ');
      expect(h.session.state.echo, isTrue);
    });
    t('ATE0 / ATH1 / ATSP6', (h) {
      expect(h.send('ATE0'), 'ATE0\rOK\r\r>');
      expect(h.send('ATH1'), 'OK\r\r>');
      expect(h.session.state.headers, isTrue);
      expect(h.send('ATSP6'), 'OK\r\r>');
      expect(h.session.state.protocol, 6);
    });
    t('ATDPN（旧: 6 → 起動直後は A0）', (h) {
      h.send('ATE0');
      expect(h.send('ATDPN'), 'A0\r\r>');
    });
    t('ATI / ATRV', (h) {
      h.send('ATE0');
      expect(h.send('ATI'), 'ELM327 v1.5\r\r>');
      expect(h.send('ATRV'), '12.4V\r\r>');
    });
    t('未知 AT は ?', (h) {
      h.send('ATE0');
      expect(h.send('ATXYZ'), '?\r\r>');
    });
    t('ATSP（引数なし）は ?（旧: OK）', (h) {
      h.send('ATE0');
      expect(h.send('ATSP'), '?\r\r>');
    });
    t('ATSP0 は自動（旧: protocol = 6）', (h) {
      h.send('ATE0');
      h.send('ATSP0');
      expect(h.session.state.autoSearch, isTrue);
      h.send('0100');
      expect(h.send('ATDPN'), 'A6\r\r>');
    });
    t('ATSPA6 は自動・6 から', (h) {
      h.send('ATE0');
      expect(h.send('ATSPA6'), 'OK\r\r>');
      expect(h.session.state.protocol, 6);
      expect(h.session.state.autoSearch, isTrue);
    });
    t('ATS0 でスペースなし（回帰防止）', (h) {
      h.send('ATE0');
      expect(h.send('ATS0'), 'OK\r\r>');
      expect(h.session.state.spaces, isFalse);
    });
  });

  group('旧 obd_command_handler_test', () {
    t('010C / 010D / 0105', (h) {
      h.quiet();
      h.vehicle
        ..rpm = 1726
        ..speedKmh = 60
        ..coolantTempC = 85;
      expect(h.send('010C'), '41 0C 1A F8 \r\r>');
      expect(h.send('010D'), '41 0D 3C \r\r>');
      expect(h.send('0105'), '41 05 7D \r\r>');
    });
    t('spaces off で連結', (h) {
      h.quiet();
      h.send('ATS0');
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '410C1AF8\r\r>');
    });
    t('headers on（旧: パディングなし）', (h) {
      h.quiet();
      h.send('ATH1');
      h.vehicle.rpm = 1726;
      expect(h.send('010C'), '7E8 04 41 0C 1A F8 00 00 00 \r\r>');
    });
    t('0100 ビットマップ（旧: 18 1B 80 01）', (h) {
      h.quiet();
      expect(h.send('0100'), '41 00 BE 3F A0 13 \r\r>');
    });
    t('03 で DTC、04 で消去', (h) {
      h.quiet();
      expect(h.send('03'), '43 01 03 01 \r\r>');
      expect(h.send('04'), '44 \r\r>');
      expect(h.engineProfile.confirmedDtcs, isEmpty);
    });
    t('0902 VIN は複数フレーム', (h) {
      h.quiet();
      expect(h.send('0902').split('\r').first, matches(RegExp(r'^[0-9A-F]{3}$')));
    });
    t('未対応 PID は NO DATA', (h) {
      h.quiet();
      expect(h.send('01FF'), 'NO DATA\r\r>');
    });
    t('初期化前の未対応 PID（旧: SEARCHING... + NO DATA）', (h) {
      h.send('ATE0');
      expect(h.send('01FF'), 'SEARCHING...\rUNABLE TO CONNECT\r\r>');
    });
    t('初期化前は SEARCHING... が先頭、以後は確立', (h) {
      h.send('ATE0');
      expect(h.send('010C').split('\r').first, 'SEARCHING...');
      expect(h.session.state.established, 6);
    });
  });
}
