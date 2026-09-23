# python-OBD による確認

オープンソースの OBD クライアント python-OBD（0.7.3）を、UI なしのエミュレータ（`bin/elm327_tcp.dart`）へ TCP でつなぎ、
接続・PID の読み取り・DTC の読み取りと消去・障害時の振る舞いを確かめる。

    uv run --with obd==0.7.3 python tool/python_obd_check/check.py

シナリオごとに別のポート（35101〜35105）でエミュレータを起動し、標準入力の制御コマンド（`delay 350` など）で障害を切り替える。
