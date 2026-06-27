package com.example.elm327emu

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import java.util.UUID
import kotlin.concurrent.thread

@SuppressLint("MissingPermission")
class SppServer(
    private val onRx: (ByteArray) -> Unit,
    private val onConn: (String, String) -> Unit,
) {
    private val sppUuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private var serverSocket: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null
    @Volatile private var running = false

    fun start() {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        running = true
        thread(name = "spp-accept") {
            try {
                serverSocket = adapter.listenUsingRfcommWithServiceRecord("ELM327", sppUuid)
                while (running) {
                    val s = serverSocket?.accept() ?: break
                    socket = s
                    onConn("connected", s.remoteDevice?.address ?: "")
                    readLoop(s)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun readLoop(s: BluetoothSocket) {
        val buf = ByteArray(1024)
        try {
            val input = s.inputStream
            while (running) {
                val n = input.read(buf)
                if (n < 0) break
                onRx(buf.copyOf(n))
            }
        } catch (_: Exception) {
        } finally {
            onConn("disconnected", s.remoteDevice?.address ?: "")
            try { s.close() } catch (_: Exception) {}
        }
    }

    fun send(bytes: ByteArray) {
        try {
            socket?.outputStream?.write(bytes)
            socket?.outputStream?.flush()
        } catch (_: Exception) {}
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
    }
}
