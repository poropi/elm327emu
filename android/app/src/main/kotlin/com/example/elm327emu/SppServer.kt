package com.example.elm327emu
class SppServer(val onRx: (ByteArray) -> Unit, val onConn: (String, String) -> Unit) {
    fun start() {}
    fun send(bytes: ByteArray) {}
    fun stop() {}
}
