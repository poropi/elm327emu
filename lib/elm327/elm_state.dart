/// ELM327 の AT 設定状態。
class ElmState {
  bool echo = true;
  bool linefeed = false;
  bool headers = false;
  bool spaces = true;
  int protocol = 6; // ISO 15765-4 CAN 11bit/500k
  bool initialized = false;

  void reset() {
    echo = true;
    linefeed = false;
    headers = false;
    spaces = true;
    protocol = 6;
    initialized = false;
  }
}
