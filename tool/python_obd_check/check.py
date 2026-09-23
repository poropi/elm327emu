"""python-OBD 0.7.3 で bin/elm327_tcp.dart を端から端まで確かめる。

実行: uv run --with obd==0.7.3 python tool/python_obd_check/check.py
"""
import pathlib
import subprocess
import sys

import obd
from obd import OBDStatus

ROOT = pathlib.Path(__file__).resolve().parents[2]
results = []
known = []  # python-OBD 側が仕様と違うために落ちる、既知の項目


def check_known_client_bug(name, cond, detail, reason):
    """条件はそのまま確かめるが、python-OBD 側の既知の不具合で落ちた場合は FAIL に数えず KNOWN と出す。"""
    if cond:
        check(name, True, detail)
        return
    known.append(name)
    print(f"KNOWN {name}  ({detail})  ← python-OBD 側の不具合: {reason}", flush=True)


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)


class Emulator:
    def __init__(self, port, *flags):
        self.port = port
        self.proc = subprocess.Popen(
            ["dart", "run", "bin/elm327_tcp.dart", "--port", str(port), "--quiet", *flags],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        for line in self.proc.stdout:
            if line.startswith("listening"):
                return
        raise RuntimeError("エミュレータが起動しなかった")

    def control(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("エミュレータが終了した")
            if line.startswith("ok"):
                return
            if line.startswith("error"):
                raise RuntimeError(line.strip())

    def close(self):
        self.proc.stdin.close()
        self.proc.terminate()
        self.proc.wait(10)


def connect(port, protocol=None):
    return obd.OBD(f"socket://127.0.0.1:{port}", protocol=protocol, timeout=1.0, fast=True)


def value(r):
    return None if r.is_null() else r.value.magnitude


def scenario_normal():
    emu = Emulator(35101)
    try:
        c = connect(35101)
        check("正常: CAR_CONNECTED", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        check("正常: プロトコル 6", c.protocol_id() == "6", c.protocol_id())
        check("正常: 対応コマンド 30 個以上", len(c.supported_commands) >= 30, str(len(c.supported_commands)))
        check("正常: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        check("正常: SPEED 0", value(c.query(obd.commands.SPEED)) == 0)
        check("正常: COOLANT 85", value(c.query(obd.commands.COOLANT_TEMP)) == 85)
        emu.control("rpm 2150")
        check("正常: RPM の変更が反映（2150）", value(c.query(obd.commands.RPM)) == 2150)
        r = c.query(obd.commands.VIN)
        check_known_client_bug(
            "正常: VIN", "WAUZZZ8K9AA000000" in str(r.value), str(r.value),
            "0.7.3 の decoders.decode_encoded_string が strip(b'\\x00' ...) で文字 '0' '1' '2' 'x' '\\' も末尾から削る",
        )
        # python-OBD の文字列デコーダを通さず、組み立て済みの 0902 応答をそのまま見る
        vin_raw = obd.OBDCommand("VIN_RAW", "VIN (raw)", b"0902", 0,
                                 lambda msgs: bytes(msgs[0].data[3:]), obd.ECU.ENGINE, True)
        r = c.query(vin_raw, force=True)
        check("正常: VIN（生データ 17 文字）", r.value == b"WAUZZZ8K9AA000000", str(r.value))
        r = c.query(obd.commands.GET_DTC)
        check("正常: DTC に P0301", any(code == "P0301" for code, _ in (r.value or [])), str(r.value))
        c.query(obd.commands.CLEAR_DTC)
        r = c.query(obd.commands.GET_DTC)
        check("正常: 消去後の DTC は空", r.value == [], str(r.value))
        r = c.query(obd.commands.ELM_VOLTAGE)
        check("正常: ELM_VOLTAGE 12.4", value(r) is not None and abs(value(r) - 12.4) < 0.05, str(r.value))
        c.close()
    finally:
        emu.close()


def scenario_faults():
    emu = Emulator(35102)
    try:
        c = connect(35102)
        check("障害: 接続", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        emu.control("delay 350")
        check("障害: 遅延 350ms → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("delay 0")
        check("障害: 遅延の解除で戻る", value(c.query(obd.commands.RPM)) == 800)
        emu.control("silent engine on")
        check("障害: エンジン無応答 → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("silent engine off")
        emu.control("error canError once")
        check("障害: CAN ERROR（1 回）→ 値なし", c.query(obd.commands.RPM).is_null())
        check("障害: 次の要求は戻る", value(c.query(obd.commands.RPM)) == 800)
        emu.control("drop 100")
        check("障害: 欠落 100% → 値なし", c.query(obd.commands.RPM).is_null())
        emu.control("drop 0")
        emu.control("disconnect")
        c.query(obd.commands.RPM)
        check("障害: 切断で NOT_CONNECTED", c.status() == OBDStatus.NOT_CONNECTED, str(c.status()))
    finally:
        emu.close()


def scenario_ignition_off():
    emu = Emulator(35103)
    try:
        emu.control("ignition off")
        c = connect(35103)
        check("イグニッション OFF: OBD_CONNECTED 止まり", c.status() == OBDStatus.OBD_CONNECTED, str(c.status()))
        c.close()
    finally:
        emu.close()


def scenario_two_ecus():
    emu = Emulator(35104, "--transmission")
    try:
        c = connect(35104)
        check("ECU 2 台: 接続", c.status() == OBDStatus.CAR_CONNECTED, str(c.status()))
        check("ECU 2 台: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        c.close()
    finally:
        emu.close()


def scenario_29bit():
    emu = Emulator(35105)
    try:
        c = connect(35105, protocol="7")
        check("29bit: プロトコル 7", c.protocol_id() == "7", c.protocol_id())
        check("29bit: RPM 800", value(c.query(obd.commands.RPM)) == 800)
        c.close()
    finally:
        emu.close()


if __name__ == "__main__":
    for s in (scenario_normal, scenario_faults, scenario_ignition_off, scenario_two_ecus, scenario_29bit):
        try:
            s()
        except Exception as e:  # シナリオの途中で落ちても残りは続ける
            check(f"{s.__name__} が例外なく終わる", False, repr(e))
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)} passed / {len(failed)} failed / {len(known)} known (python-OBD 側)")
    sys.exit(1 if failed else 0)
