# ELM327 エミュレータ 完全化（仮想 CAN バス化・AT 全対応・障害注入）設計書

- 日付: 2026-09-23
- ステータス: レビュー待ち
- 前提: [2026-06-27 初版設計](2026-06-27-elm327-emulator-flutter-design.md) で作った Flutter / Android + macOS のエミュレータを拡張する
- UI 画面案: https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa （ユーザー確認済み）

## 1. 目的と合意事項

### 目的

自作 OBD クライアントと市販・汎用 OBD クライアント（Torque, Car Scanner, OBD Auto Doctor 等）の両方を、実車なしで
「初期化 → PID 読み取り → DTC 読み取り・消去」まで通せるようにする。加えて、エラー応答・遅延・切断を UI から
起こし、クライアント側のエラー処理を試せるようにする。

### ユーザーと合意した範囲

| 論点 | 決定 |
|---|---|
| 対象クライアント | 自作・汎用の両方 ＋ 異常系テスト（案 C） |
| プロトコル | CAN のみ（ATSP 6〜9）。1〜5, A〜C は `UNABLE TO CONNECT` |
| メーカ診断 | Mode 22（ReadDataByIdentifier）＋ 否定応答まで。セッション制御・SecurityAccess はしない |
| 構造 | 仮想 CAN バスを導入して作り直す（案 1） |
| AT コマンド | データシートの一覧全項目を 4 段階（動作 / 保存 / OK / ?）のどれかで扱う |
| UI | 6 タブ（接続 / 車両 / DTC / ECU / 障害 / ログ）。画面案どおり |
| 検証 | 開発用 TCP 経路を追加し、python-OBD（オープンソースの実クライアント）で端から端まで確かめる |

### 一次情報

- ELM327 データシート（ELM327DSI, v2.0 版, 82 ページ）: https://cdn.sparkfun.com/assets/learn_tutorials/8/3/ELM327DS.pdf
  - AT コマンド一覧 p.9–10、各コマンドの説明 p.11〜、エラーメッセージ p.78–80
- OBD-II PID 一覧（SAE J1979 の要約）: https://en.wikipedia.org/wiki/OBD-II_PIDs
  - Service 01 の PID 表、Service 09 の PID 表、Service 01 PID 01 のビット配置、CAN 11bit の要求・応答形式

### 未確認の前提（実装で仮置きし、報告で明記する）

1. v1.5 の実機が v2.0 で追加されたコマンド（`AMC`, `AMT`, `FE`, `SH wwxxyyzz`, `PP` 系の一部など）に何を返すか。
   本設計ではすべて受け付ける。
2. 全 ECU 宛て（functional）の OBD 要求で、未対応 PID / サービスに ECU が否定応答せず黙る（ISO 15765-4）。
   規格本文は未確認。Wikipedia の記述と一般的な実車挙動に基づく。
3. `STOPPED` を起こした割り込み文字そのものが、次のコマンドの先頭として扱われるか捨てられるか。本設計では捨てる。
4. `7F xx 78`（応答保留）を受けたとき ELM327 がその行を表示するか・待ち時間を延長するか。本設計では
   行を表示し、本来の応答が来るまで待ち時間を延長する。
5. `ATMA` 中の表示形式（CAF1 でも PCI を表示するか）。本設計では生の 8 バイトを表示する。
6. S1 のとき、データ行の末尾にスペースが付くか（既存実装は付けている。データシートの例からは判別できない）。

## 2. スコープ

### 含む

- ELM 層の作り直し（AT 全項目、表示形式、非同期出力、`STOPPED`、`<CR>` 繰り返し、応答数指定）
- 仮想 CAN バス、ISO-TP（ECU 側送信・ELM 側受信・フロー制御）
- ECU 2 台（エンジン・トランスミッション）、OBD Mode 01〜0A（05 と 08 を除く）、Mode 22、否定応答
- 車両状態の拡張（PID 38 項目分の値、DTC 3 種、フリーズフレーム、Mode 09 情報、DID 表）
- 障害注入（§7）と切断（ネイティブ層に `disconnect` を追加）
- 開発用 TCP 経路（macOS アプリ内、および UI なしの Dart CLI）
- UI を 6 タブに再構成
- python-OBD による端から端までの検証スクリプト

### 含まない

- CAN 以外のプロトコル（ISO 9141-2, ISO 14230-4 KWP, SAE J1850, J1939 の中身）
- UDS のセッション制御（10）、Tester Present（3E）、SecurityAccess（27）、書き込み（2E）、ルーチン（31）、UDS DTC（19 / 14）
  → いずれも ECU 指定なら `7F xx 11`、全 ECU 宛てなら無応答
- Mode 05（非 CAN 専用）、Mode 08（車載システム制御）
- 設定の永続化（アプリ再起動で初期値に戻る。現状どおり）
- Bluetooth 経由で市販クライアントを動かす確認（ユーザーの手元で行う。§10）

## 3. 全体構成

```
クライアント
  │ BLE / SPP（ネイティブ）  または  TCP（開発用・Dart）
  ▼
ElmSession（1 接続に 1 つ）
  ├─ LineAssembler … バイト → コマンド行
  ├─ AtCommands … AT を表で処理 → ElmState を更新
  ├─ RequestRouter … OBD/UDS 行 → ISO-TP 単一フレーム → バスへ。応答フレームを集めて ISO-TP 復元
  └─ ResponseFormatter … 復元したメッセージ／フレームを ElmState に従って文字列化
  │  CanFrame
  ▼
FaultInjector … 無応答・遅延・欠落・エラー・応答保留・途中欠落
  ▼
VirtualCanBus … フレームを配信。ECU の応答フレームを返す。周期フレームを流す（ATMA 用）
  ├─ Ecu(エンジン 7E0/7E8)
  └─ Ecu(トランスミッション 7E1/7E9)
        └─ ObdServices / UdsServices … VehicleState と EcuProfile を読んで応答を作る
```

### ファイル構成

```
lib/
├── elm327/
│   ├── elm_session.dart        入力バイト → 出力 Stream。状態 idle / busy / monitoring / lowPower
│   ├── elm_state.dart          AT 設定（拡張）。reset() と defaults() を分ける（ATZ と ATD の差）
│   ├── at_commands.dart        AT の表（パターン → ハンドラ）
│   ├── line_assembler.dart     既存を拡張（空行を通す・スペースと制御文字を捨てる・長さ上限）
│   ├── request_router.dart     要求の組み立て・送信・収集・待ち時間
│   ├── iso_tp.dart             分割（ECU 側）と復元（ELM 側）、FC の生成
│   └── response_formatter.dart ヘッダ / スペース / DLC / CAF / 複数フレーム / 複数 ECU の表示
├── can/
│   ├── can_frame.dart          id, is29bit, data(0〜8), rtr
│   ├── virtual_can_bus.dart    send(frame) → 応答を Stream で返す。periodic フレームの Stream
│   └── fault_injector.dart     FaultConfig を読んでフレームの流れを変える
├── ecu/
│   ├── ecu.dart                EcuProfile（ID、有効、DTC、Mode 09 情報、DID 表）と要求の振り分け
│   ├── obd_services.dart       Mode 01/02/03/04/06/07/09/0A
│   ├── uds_services.dart       Mode 22 と否定応答
│   └── pid_table.dart          PID 定義（PID, バイト数, エンコード関数, 対応 ECU）とビットマップ生成
├── vehicle/
│   ├── vehicle_state.dart      値を拡張（§6.2）
│   └── simulator.dart          派生値の計算と積算（経過時間・距離）を追加
├── transport/
│   ├── transport.dart          TransportType に tcp を追加
│   ├── transport_bridge.dart   disconnect を追加
│   └── tcp_transport.dart      dart:io ServerSocket（127.0.0.1:35000、同時 1 接続）
├── app/emulator_controller.dart セッションを接続ごとに持つ。FaultConfig を持つ
└── ui/                          6 タブ（§8）
bin/
└── elm327_tcp.dart             UI なしで TCP 待ち受けする CLI（python-OBD 検証用、Flutter 非依存）
tool/
└── python_obd_check/           python-OBD の検証スクリプトと requirements.txt
```

`lib/elm327`, `lib/can`, `lib/ecu`, `lib/vehicle` は Flutter に依存させない（`bin/` の CLI から使うため）。

旧 `Elm327Engine`, `AtCommandHandler`, `ObdCommandHandler` は削除する。`obd_encoding.dart` の関数は
`pid_table.dart` / `iso_tp.dart` / `response_formatter.dart` に移す。

※実装との差（2026-09-24）: `request_router.dart` は作らなかった。要求の組み立て・送信・応答の収集・待ち時間は
`ElmSession`（`lib/elm327/elm_session.dart`）の中にある。

## 4. ElmSession（非同期の振る舞い）

### インタフェース

```dart
class ElmSession {
  ElmSession({required VirtualCanBus bus, required FaultInjector faults, required Clock clock});
  void input(List<int> bytes);          // Transport から受信したバイト
  Stream<List<int>> get output;         // Transport へ送るバイト
  ElmState get state;                   // UI 表示用（読み取り専用）
  void dispose();
}
```

### 状態遷移

| 状態 | 入力を受けたとき |
|---|---|
| idle | 文字を行に組み立てる。CR で 1 行を処理して busy へ |
| busy（応答待ち） | 1 バイトでも受けたら処理を中断し `STOPPED` を出して idle。受けた文字は捨てる（未確認 3） |
| monitoring（ATMA/MR/MT） | 同上。`STOPPED` を出して idle |
| lowPower（ATLP 後） | 何か受けたら復帰して idle（応答は出さない） |

### 出力の形

- エコー（E1）: 受けた行と CR をそのまま返す。
- 応答行の区切りは CR（L1 なら CR LF）。
- 応答の終わりに空行 1 つとプロンプト `>`。
- `ATZ` / `ATWS`: 実機どおり、ID の前に空行を入れる（`\r\rELM327 v1.5\r\r>`）。

### 行の解釈

1. 空行（CR のみ）: 直前のコマンドを繰り返す。直前がなければ何もしない（`>` のみ）。
2. スペースと、CR 以外の制御文字は捨てる。大文字小文字は区別しない。
3. `AT` で始まれば AtCommands へ。
4. それ以外は 16 進として解釈する。16 進以外の文字・奇数桁・空は `?`。
5. 末尾 1 桁（奇数桁のとき最後の 1 文字）が `1`〜`F` なら応答数指定として取り除く（`010C1` → `010C`、期待 1 件）。
6. データ長の上限: CAF1 は 7 バイト、CAF0 は AL なら 8・NL なら 7 バイト（PCI 込み）。超えたら `?`。

### 待ち時間（RequestRouter）

- `ST hh`: タイムアウト = hh × 4ms（初期値 0x32 = 200ms）。`ST 00` は初期値に戻す。
- AT0: 最後の応答フレームから ST の時間だけ待って確定。
- AT1 / AT2: 最後の応答フレームから min(ST, 50ms) 待って確定（実機の適応タイミングの近似。AT2 は AT1 と同じ扱い）。
- 応答数指定があれば、その数のメッセージが揃った時点で確定。
- 1 件も応答がなければ ST 経過で `NO DATA`。
- `R0`（応答オフ）: 送信後すぐに `>` を返す。
- 自動選択モード（SP 0 / SP Ah）で、プロトコル確定前の最初の OBD 要求は `SEARCHING...` を先に出す。
  応答があればプロトコルが確定（DPN が `A6` 等）。応答がなければ `UNABLE TO CONNECT`。
- 時刻は `Clock` 抽象経由で取り、テストでは `fakeAsync` で進める。

※実装との差（2026-09-24）: BLE・SPP・TCP の各セッションは 1 本の VirtualCanBus を共有したまま、互いの要求・応答に
干渉しない。ECU は要求の送信元を覚えて、その要求への応答フレームすべてに「どの要求者への応答か」（`BusEvent.replyTo`）を付け、
ISO-TP の送信状態（残りフレーム・FC 待ち）を要求者ごとに持つ。FC はそれを送ったセッションへの送信にだけ効く。
応答待ち中のセッションは、他のセッションが送ったフレームと、他のセッション宛ての応答を使わない（FC も返さない）。
監視中（ATMA / MR / MT）のセッションは従来どおりバス上の全フレームを表示する。

## 5. AT コマンド

段階の意味: **動作** = 応答や表示に実際に効く / **保存** = 値を保持し読み出せる /
**OK** = 受理して `OK` のみ / **?** = 実機でも今のプロトコルでは実行できないため `?`。

パラメータ不正（桁数違い・16 進以外）はすべて `?`。

### 全般

| コマンド | 段階 | 応答・動作 |
|---|---|---|
| `<CR>` | 動作 | 直前のコマンドを繰り返す |
| `Z` | 動作 | 全リセット（ElmState.reset）。`\r\rELM327 v1.5` |
| `WS` | 動作 | Z と同じ |
| `D` | 動作 | 設定を初期値に（ElmState.defaults）。`OK` |
| `I` | 動作 | `ELM327 v1.5` |
| `@1` | 動作 | `OBDII to RS232 Interpreter`（p.21 の初期文字列） |
| `@2` | 動作 | `@3` で保存した文字列。未保存なら `?` |
| `@3 cccccccccccc` | 保存 | 12 文字を保存（アプリ起動中のみ）。`OK` |
| `E0` / `E1` | 動作 | エコー |
| `L0` / `L1` | 動作 | 改行に LF を付けるか |
| `M0` / `M1` | 保存 | `OK` |
| `SD hh` / `RD` | 保存 | 1 バイト保存 / 読み出し（`RD` は `hh`） |
| `BRD hh` | OK | 実機は速度変更の手順を踏むが、BLE/SPP/TCP では無意味のため `OK` |
| `BRT hh` | OK | |
| `FE` | OK | |
| `LP` | 動作 | `OK` を返して lowPower へ |
| `PP xx ON` / `PP xx OFF` / `PP FF ON` / `PP FF OFF` / `PP xx SV yy` | 保存 | `OK` |
| `PPS` | 動作 | PP 番号・コロン・値・`N`（有効）/`F`（無効）の並び（p.22）。例 `00:FF F  01:FF F  02:FF F  03:32 F`。1 行 4 項目、00〜2F |
| `CV dddd` | 動作 | 表示電圧を dd.dd V に補正。`OK` |
| `CV 0000` | 動作 | 補正を解除。`OK` |
| `RV` | 動作 | `14.2V` のように車両電圧（補正込み、小数 1 桁） |
| `IGN` | 動作 | 障害「イグニッション OFF」に応じて `ON` / `OFF` |

### OBD 全般

| コマンド | 段階 | 応答・動作 |
|---|---|---|
| `AL` / `NL` | 動作 | 長いメッセージの許可（§4 の上限） |
| `AMC` | 動作 | 最後の OBD 通信からの経過を 0.65536 秒単位で `hh`（上限 FF） |
| `AMT hh` | 保存 | `OK` |
| `AR` | 動作 | 受信アドレスを送信ヘッダから自動決定（初期値） |
| `AT0` / `AT1` / `AT2` | 動作 | §4 |
| `BD` | 動作 | 長さ 1 バイト + OBD バッファ 12 バイト（p.12）。最後に送受信したメッセージを入れる（例 `03 7E 80 04 41 0C 21 98 00 00 00 00 00`、ID の格納方法は近似） |
| `BI` | OK | |
| `DP` | 動作 | 6: `ISO 15765-4 (CAN 11/500)`、7: `ISO 15765-4 (CAN 29/500)`、8: `ISO 15765-4 (CAN 11/250)`、9: `ISO 15765-4 (CAN 29/250)`。自動選択中は先頭に `AUTO, `。CAN 以外を指定中は該当プロトコル名（例 `SAE J1850 PWM`）のみ返す |
| `DPN` | 動作 | 自動なら `A` + 番号（`A6`）、固定なら番号のみ（p.16「自動検索が有効なら A を前置」） |
| `H0` / `H1` | 動作 | ヘッダ表示 |
| `MA` | 動作 | 監視開始（§7.3） |
| `MR hh` / `MT hh` | 動作 | 受信側 / 送信側アドレスで絞って監視（29bit は該当バイト、11bit は ID 下位 8bit で比較） |
| `PC` | OK | |
| `R0` / `R1` | 動作 | 応答を待つか |
| `RA hh` / `SR hh` | 動作 | 受信アドレスを固定（29bit の宛先バイト、11bit は ID 下位 8bit） |
| `S0` / `S1` | 動作 | スペース |
| `SH xyz` / `SH xxyyzz` / `SH wwxxyyzz` | 動作 | 送信ヘッダ。3 桁は 11bit ID、6 桁は 29bit の下位 3 バイト（上位は CP）、8 桁は 29bit 全体 |
| `SP h` / `SP Ah` / `SP 00` | 動作 | 6〜9 は CAN。0 と A は自動（開始 6）。1〜5, A〜C 指定後の OBD 要求は `UNABLE TO CONNECT` |
| `TP h` / `TP Ah` | 動作 | SP と同じ（保存しない違いのみ） |
| `SS` | OK | |
| `ST hh` | 動作 | §4 |
| `TA hh` | 動作 | 29bit の送信元バイト（初期 F1） |

### CAN

| コマンド | 段階 | 応答・動作 |
|---|---|---|
| `CAF0` / `CAF1` | 動作 | PCI の自動付与・自動除去 |
| `CEA` / `CEA hh` | 動作 | 拡張アドレス。付けると送信データの先頭に hh を付ける（ECU は拡張アドレス付きフレームには応答しない＝NO DATA） |
| `CF hhh` / `CF hhhhhhhh` | 動作 | 受信 ID フィルタ |
| `CM hhh` / `CM hhhhhhhh` | 動作 | 受信 ID マスク |
| `CFC0` / `CFC1` | 動作 | FC を自動送信するか。CFC0 では ECU の複数フレーム応答は最初のフレームで止まる |
| `CP hh` | 動作 | 29bit の優先度バイト（初期 18） |
| `CRA` / `CRA hhh` / `CRA hhhhhhhh` | 動作 | 受信アドレスフィルタ（引数なしで解除） |
| `CS` | 動作 | `T:00 R:00`（送信 / 受信エラー数。障害でエラーを起こすと増える） |
| `CSM0` / `CSM1` | OK | |
| `D0` / `D1` | 動作 | DLC 表示 |
| `FC SM h` / `FC SH …` / `FC SD …` | 保存 | `OK`（SM は 0〜2 のみ、それ以外 `?`） |
| `PB xx yy` | 保存 | `OK` |
| `RTR` | 動作 | RTR フレームを送信。ECU は応答しない。`>` のみ（空応答） |
| `V0` / `V1` | 動作 | V1 のとき送信フレームを詰めない（パディングしない） |

### J1850 / ISO / J1939（CAN 以外）

| コマンド | 段階 |
|---|---|
| `IFR0` `IFR1` `IFR2` `IFRH` `IFRS` / `IB10` `IB48` `IB96` / `IIA hh` / `KW0` `KW1` / `SW hh` / `WM …` / `JE` `JS` / `JHF0` `JHF1` / `JTM1` `JTM5` | OK |
| `FI` / `SI` / `KW` / `DM1` / `MP hhhh [n]` / `MP hhhhhh [n]` | ? |

### 上記以外

`?`。

※実装との差（2026-09-24）: 表の `MR hh` の 11bit の比較は「ID 下位 8bit」ではなく、ID の bit 8〜10 と比べる
（データシート ELM327DSJ p.22「bits 8 to 10 of an 11 bit CAN ID」どおり。設計書の記述が誤り）。

## 6. ECU とサービス

### 6.1 ECU

| ECU | 11bit 要求 → 応答 | 29bit 要求 → 応答 | 初期状態 |
|---|---|---|---|
| エンジン | 7E0 → 7E8 | 18DA10F1 → 18DAF110 | 有効 |
| トランスミッション | 7E1 → 7E9 | 18DA18F1 → 18DAF118 | 無効 |

- 全 ECU 宛て: 11bit `7DF`、29bit `18DB33F1`。有効な ECU がすべて応答する。
- ECU 応答の基本遅延: エンジン 8ms、トランスミッション 15ms（複数 ECU の応答順を固定するため）。障害の遅延はこれに加算。
- 送信フレームのパディング: ELM 側は 0x00（データシート p.62 の PP 26「CAN filler byte」初期値 00）。ECU 側も 0x00
  （データシート p.40・p.44 の受信例がすべて 00 で埋まっているため。Wikipedia は 0xCC を推奨と記載）。
- ボーレート（プロトコル 6/7 = 500k、8/9 = 250k）は表示のみ。バスはどちらでも応答する。
- 11bit プロトコル（6/8）中は 29bit の ID で送っても ECU は応答しない（逆も同じ）→ `NO DATA`。

※実装との差（2026-09-24）: ECU は 29bit ID の先頭（優先度）バイトを見ない（2・3 バイト目の `DA xx` / `DB 33` だけで
宛先を判断し、下位バイトの送信元は応答 ID に使う）。実機 ECU がどう扱うかは確かめていない割り切り。

### 6.2 Mode 01

PID 定義は `pid_table.dart` の表（PID、バイト数、エンコード、対応 ECU）。ビットマップ（00, 20, 40, 60, 80, A0）は
表から生成し、次の範囲に対応 PID があればその範囲のビットマップ PID 自身のビットも立てる。

| PID | 内容 | バイト | エンコード（Wikipedia の式の逆） | 値の出所 |
|---|---|---|---|---|
| 01 | モニタ状態 | 4 | A = MIL(bit7) + 確定 DTC 数、B/C/D はレディネス（下記） | DTC・消去状態 |
| 03 | 燃料系の状態 | 2 | 02 00（閉ループ） | 固定 |
| 04 | エンジン負荷 | 1 | A = %×255/100 | engineLoadPct |
| 05 | 水温 | 1 | A = °C+40 | coolantTempC |
| 06 | 短期燃料トリム B1 | 1 | A = (%+100)×128/100 | stftPct |
| 07 | 長期燃料トリム B1 | 1 | 同上 | ltftPct |
| 0B | 吸気管圧力 | 1 | A = kPa | mapKpa |
| 0C | 回転数 | 2 | (A×256+B) = rpm×4 | rpm |
| 0D | 車速 | 1 | A = km/h | speedKmh |
| 0E | 点火時期 | 1 | A = (°+64)×2 | timingDeg |
| 0F | 吸気温 | 1 | A = °C+40 | intakeTempC |
| 10 | MAF | 2 | (A×256+B) = g/s×100 | maf |
| 11 | スロットル | 1 | A = %×255/100 | throttlePct |
| 13 | O2 センサの有無 | 1 | 03（B1S1, B1S2） | 固定 |
| 1C | OBD 規格 | 1 | 06（EOBD） | 固定 |
| 1F | 始動後経過 | 2 | 秒 | runTimeSec |
| 21 | MIL 点灯後の距離 | 2 | km | distanceWithMilKm |
| 2F | 燃料残量 | 1 | A = %×255/100 | fuelLevelPct |
| 30 | 消去後のウォームアップ回数 | 1 | 回 | warmupsSinceClear |
| 31 | 消去後の距離 | 2 | km | distanceSinceClearKm |
| 33 | 大気圧 | 1 | kPa | baroKpa |
| 3C | 触媒温度 B1S1 | 2 | (A×256+B) = (°C+40)×10 | catalystTempC |
| 41 | 今回サイクルのモニタ状態 | 4 | 01 と同じ構成（A は 00） | 消去状態 |
| 42 | 制御モジュール電圧 | 2 | mV | batteryVoltage |
| 43 | 絶対負荷 | 2 | (A×256+B) = %×255/100 | absLoadPct |
| 44 | 指令空燃比（λ） | 2 | (A×256+B) = λ×32768 | lambda |
| 45 | 相対スロットル | 1 | %×255/100 | throttlePct から派生 |
| 46 | 外気温 | 1 | °C+40 | ambientTempC |
| 47 | 絶対スロットル B | 1 | %×255/100 | 派生 |
| 49 | アクセル開度 D | 1 | %×255/100 | acceleratorPct |
| 4A | アクセル開度 E | 1 | %×255/100 | 派生 |
| 4C | 指令スロットル | 1 | %×255/100 | 派生 |
| 4D | MIL 点灯時間 | 2 | 分 | minutesWithMil |
| 4E | 消去後の時間 | 2 | 分 | minutesSinceClear |
| 51 | 燃料の種類 | 1 | 01（ガソリン） | 固定 |
| 5C | 油温 | 1 | °C+40 | oilTempC |
| 5E | 燃料消費率 | 2 | (A×256+B) = L/h×20 | fuelRateLph |
| A6 | 走行距離計 | 4 | km×10 | odometerKm |

トランスミッション ECU の Mode 01: `00`, `01`（自分の DTC 数）, `A4`（実ギア: A = 02（対応ビット）、B = 0、
C/D = 変速比×1000）, ビットマップ `20`〜`A0`。ギアと変速比は車速から派生。

**レディネス（01 / 41 の B, C, D）**: 火花点火車。B = 共通 3 テスト（ミスファイア・燃料系・コンポーネント）が
対応済みかつ完了。C = 触媒・EVAP・O2・O2 ヒーターが対応。D = 完了ビット（0 = 完了）。
DTC 消去直後は D を C と同じ（全未完了）にし、動的シミュレーションで 60 秒ごとに 1 項目ずつ完了させる。

**複数 PID 要求**（`01 0C 0D 05`）: 最大 6 個。各 ECU は対応 PID のみを順に並べた 1 メッセージ
（`41 0C xx xx 0D xx 05 xx`）で応答し、7 バイトを超えれば ISO-TP の複数フレームになる。
対応 PID が 1 つもない ECU は応答しない。7 個以上は `?`。

### 6.3 その他の OBD モード

| モード | 動作 |
|---|---|
| 02 | 要求は `02 PID 00`（フレーム番号 00 のみ。それ以外は無応答）。フリーズフレームは確定 DTC を追加した瞬間の Mode 01 全値のスナップショット（1 件、最初の 1 回のみ保存。消去で破棄）。`02 02 00` → 原因 DTC、`02 00 00` → 保存 PID のビットマップ。未保存なら無応答 |
| 03 | `43 件数 DTC…`。0 件は `43 00`。7 バイト超は複数フレーム |
| 04 | 確定・保留 DTC、フリーズフレームを消去。01 の MIL と件数、21/31/4D/4E/30 を 0、レディネスを未完了に戻す。永続 DTC は残す。`44` |
| 06 | `06 00` → サポート MID ビットマップ（01, 21, A2）。`06 01`（O2 B1S1）、`06 21`（触媒 B1）、`06 A2`（ミスファイア 1 番）は `46 MID` + テストごとに `TID 単位 値(2) 最小(2) 最大(2)`。値は合格範囲内の固定値 |
| 07 | 保留 DTC。形式は 03 と同じ（応答 SID 47） |
| 09 | `00` → `49 00 54 40 00 00`（02, 04, 06, 0A 対応）。`02` → `49 02 01` + VIN 17 バイト。`04` → `49 04 01` + CALID 16 バイト（不足は 00）。`06` → `49 06 01` + CVN 4 バイト。`0A` → `49 0A 01` + ECU 名 20 バイト（不足は 00） |
| 0A | 永続 DTC。形式は 03 と同じ（応答 SID 4A） |

### 6.4 Mode 22 と否定応答

- ECU 指定（物理アドレス）の要求のみ応答する。全 ECU 宛ての 22 は無応答。
- 要求は `22 DID(2 バイト)`。DID は 1 つのみ（複数指定は `7F 22 13`）。
- 応答 `62 DID 値…`。7 バイトを超えれば複数フレーム。
- DID 表は ECU ごと。値の形式は ASCII または HEX。初期値（エンジン）: F190 = VIN、F187 = 部品番号、
  F18C = シリアル番号、F191 = ハードウェア番号（HEX）。トランスミッションは F187 と F18C のみ。

| 状況 | 応答 |
|---|---|
| 表にない DID | `7F 22 31` |
| 長さ不正 | `7F 22 13` |
| OBD 以外の未対応サービス（ECU 指定） | `7F SID 11` |
| OBD 以外の未対応サービス（全 ECU 宛て） | 無応答 |
| OBD モードの未対応 PID（指定・全体とも） | 無応答（未確認 2） |

## 7. 表示形式・障害注入・監視

### 7.1 ResponseFormatter

入力: ECU ごとの受信フレーム列（ISO-TP 復元前）と ElmState。出力: 表示行。

| 条件 | 表示 |
|---|---|
| H0, CAF1, 単一フレーム | PCI とパディングを除いたデータのみ `41 0C 21 98` |
| H0, CAF1, 複数フレーム | 1 行目に総バイト数 3 桁（`014`）、続けて `0: …`, `1: …` …（連番は 16 進 1 桁、F の次は 0）。最終フレームのパディングは除く |
| H1（CAF1 / CAF0 とも） | 受信フレームをそのまま表示: ID, PCI, 8 バイト全部（パディング込み）。11bit: `7E8 04 41 0C 21 98 00 00 00`、29bit: `18 DA F1 10 04 41 0C 21 98 00 00 00`。複数フレームも 1 フレーム 1 行（`7E8 10 14 49 02 01 …`, `7E8 21 …`）。根拠: データシート p.12「H1 は CAF1 の整形を一部無効にし、受信バイトを CAF0 のように表示する」と p.40 の例 `7E8 03 41 05 46 00 00 00 00` |
| H0, CAF0 | PCI とパディングを含む受信データ 8 バイト全部（`04 41 0C 21 98 00 00 00`）。p.12「CAF0 は受信データバイトをすべて表示」 |
| D1 | ID の後に DLC 1 桁（`7E8 8 04 41 0C 21 98 00 00 00`） |
| S0 | 全区切りのスペースなし（`7E804410C2198000000`） |
| 複数 ECU | 受信順に行を並べる。H0 の複数フレームは ECU ごとに総バイト数ブロックを出す（p.44 の例のとおり、ECU の応答が交互に届けば交互に表示される。本エミュレータは ECU の基本遅延が違うため通常は交互にならない） |
| 受信フィルタ（CRA / CF・CM / RA） | 合わないフレームは表示しない。全部落ちれば `NO DATA` |
| RTR 受信（監視中） | CAF0 または H1 のとき `RTR` を表示。CAF1 かつ H0 では表示しない（p.45） |
| FC（監視中） | `FC: ` を先頭に付けて表示（p.45） |

S1 のときの行末スペース: 既存実装どおり、データ行の末尾にスペース 1 つを付ける。データシートの例には行末スペースが
見えないため、実機と一致するかは未確認（未確認 6）。

### 7.2 障害注入（FaultInjector）

| 障害 | 効果 |
|---|---|
| イグニッション OFF | 全 ECU 無応答。自動選択中は `SEARCHING...` → `UNABLE TO CONNECT`、プロトコル確定済みなら `CAN ERROR`。`ATIGN` は `OFF` |
| ECU 無応答（ECU ごと） | その ECU のフレームを捨てる |
| 応答の遅延（0〜2000ms） | ECU 応答フレームを遅らせる。ST を超えれば `NO DATA` |
| ランダム欠落（0〜100%） | 要求ごとに、その割合で全応答を捨てる（乱数は種を固定できる。テスト用） |
| 応答保留 | ECU 指定の要求に `7F SID 78` を先に返し、1000ms 後に本来の応答（未確認 4） |
| 複数フレームの途中欠落 | FF のみ返し CF を捨てる。ELM は ST 経過で、受けた分の行を出したうえで終わる（H0 は総バイト数と `0:` 行のみ） |
| エラー応答 | `CAN ERROR`, `BUS ERROR`, `BUS BUSY`, `BUFFER FULL`, `DATA ERROR`, `<DATA ERROR`（最後のデータ行の直後に付ける）, `<RX ERROR`（同）, `FB ERROR`, `ERR94`, `LV RESET`, `ACT ALERT` を、「次の 1 回」または「常に」OBD 要求の応答として返す。`ERR94` と `LV RESET` は ElmState.reset() も行う |
| 切断 | ネイティブ `disconnect(transport)`。TCP はソケットを閉じる |

エラーを起こすと `ATCS` のカウンタを増やす。有効な障害は UI の障害タブ上部に一覧表示する。

### 7.3 監視（ATMA / MR / MT）と周期フレーム

- VirtualCanBus は 11bit プロトコル中、エミュレータ独自の周期フレームを流す:
  `0C9`（回転数・20ms）、`3E9`（車速・100ms）、`4C1`（水温・1000ms）。実在車種の形式ではない。
- 監視中は周期フレームと、ほかのセッションの診断フレームを 1 フレーム 1 行で表示する
  （ヘッダは H 設定に従う。データは生の 8 バイト＝CAF0 相当。未確認 5）。
- 29bit プロトコル中は診断フレームのみ。
- 何か受信したら `STOPPED` → idle。

※実装との差（2026-09-24）: 周期フレーム（0C9・3E9・4C1）は応答待ち中の応答の収集にも待ち時間の再設定にも使わない
（受信フィルタで通しても応答行にならない）。監視中は表示する。

## 8. Transport とネイティブ変更

| 変更 | 内容 |
|---|---|
| `disconnect` メソッド | Android: BLE は `gattServer.cancelConnection(device)`、SPP はクライアントソケットを閉じてサーバは待ち受け継続。macOS: `removeAllServices` + `stopAdvertising` → 再登録 + 広告再開（疑似切断。README と UI に明記） |
| TCP（Dart） | `TcpTransport`：`ServerSocket.bind(loopbackIPv4, 35000)`、同時 1 接続（2 本目は即切断）。macOS の UI にのみ表示。macOS の entitlements に `com.apple.security.network.server`（DebugProfile は既存、Release に追加が必要か確認） |
| CLI | `dart run bin/elm327_tcp.dart [--port 35000] [--transmission] [--fault …]`。Flutter 非依存で同じ ElmSession を使う |
| セッション | EmulatorController は Transport ごとに ElmSession を持つ（BLE / SPP / TCP で AT 状態を分ける）。VehicleState、ECU、バス、障害設定は共有 |

## 9. UI

画面案（https://claude.ai/artifact/61KqqepiJ9HL5DBXmCfKJa ）どおり、上部タブ 6 つ。

| タブ | 内容 |
|---|---|
| 接続 | BLE（開始・停止・切断、プロファイル）、SPP（Android のみ）、TCP（macOS のみ）、ELM の現在状態（プロトコル・ヘッダ・表示設定・CAF/AL・ST/AT・フィルタ）、最近のやりとり 4 行とログへのリンク |
| 車両 | 動的 / 手動、イグニッション、基本 6 項目（回転数・車速・水温・スロットル・負荷・電圧）のスライダ（動的中は表示のみ）、その他の PID（最初 12 項目、「すべて表示」で全項目） |
| DTC | ECU 切替、MIL 状態、確定 / 保留 / 永続 DTC の追加・削除（`[PCBU][0-3][0-9A-F]{3}` 以外は追加不可）、フリーズフレーム、消去ボタン（Mode 04 と同じ処理） |
| ECU | 各 ECU の有効化と ID 表示、ECU 切替、Mode 09 情報（VIN は 17 文字チェック）、Mode 22 DID 表（追加・編集・削除、形式 ASCII / HEX） |
| 障害 | 有効な障害の一覧、イグニッション OFF、切断、ECU 無応答、遅延・欠落スライダ、応答保留、途中欠落、エラー応答（種類・次の 1 回 / 常に・実行） |
| ログ | 絞り込み（すべて / ELM 文字列 / CAN フレーム / 障害）、自動スクロール、コピー、クリア。最大 2000 行 |

## 10. テストと完了の基準

### テスト

1. 単体テスト（Dart、`flutter test`）: LineAssembler、ElmState、各 AT コマンド（§5 の表の全行を 1 件以上）、
   ISO-TP、ResponseFormatter（§7.1 の表の全行）、各 PID のエンコード（Wikipedia の式で逆算して一致）、各モード、
   Mode 22 と否定応答、障害の各種、ATMA、STOPPED、`<CR>` 繰り返し、応答数指定、タイミング（`fakeAsync`）。
2. 既存テスト 44 件は期待値を変えずに新 API（`input` → `output` を集める）へ移す。ただし既存の期待値が本設計と
   矛盾するもの（例: ATSP6 固定時の `SEARCHING...`）は、差分と理由を報告して直す。
3. 壊して確かめる: 主要テストについて、実装を一時的に壊して落ちることを確認する。
4. python-OBD 検証（`tool/python_obd_check/`）: `bin/elm327_tcp.dart` を起動し、python-OBD を
   `socket://127.0.0.1:35000` で接続して以下を確認する。
   - 接続成功、プロトコル認識、`supported_commands` の取得
   - RPM・車速・水温など主要 PID の値が VehicleState と一致
   - 複数 PID、VIN（09 02）、DTC 読み取り（03）と消去（04）
   - 異常系: イグニッション OFF で接続失敗が報告される、ECU 無応答で値が None、遅延が ST 超過で None、
     切断でエラー
5. ビルド: `flutter build apk --debug` と `flutter build macos --debug` が通る。`flutter analyze` がクリーン。

### 完了の基準

- §5 の全行が表どおりに動く（テストで 1 行ずつ確認）
- §6 の PID とモードがすべて表どおりの形式で応答する
- §7 の障害がすべて UI から起こせ、ログとクライアント側で観測できる
- python-OBD が §10.4 の正常系・異常系をすべて通る
- Android / macOS のビルドが通る

### 完了に含めないもの（ユーザーの手元で確認）

- Bluetooth 経由での Torque / Car Scanner / 自作クライアントの接続（README のチェックリストに追加する）
- macOS の疑似切断がクライアントからどう見えるか
