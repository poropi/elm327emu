package com.example.elm327emu

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class Elm327Plugin(private val context: Context) {
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var ble: BleGattServer? = null
    private var spp: SppServer? = null

    fun register(control: MethodChannel, eventChannel: EventChannel) {
        control.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(listOf("ble", "spp"))
                "startBle" -> {
                    val fff0 = call.argument<String>("profile") == "fff0"
                    ble?.stop()
                    ble = BleGattServer(context, rx("ble"), conn("ble")).also { it.start(fff0) }
                    result.success(null)
                }
                "stopBle" -> { ble?.stop(); ble = null; result.success(null) }
                "startSpp" -> {
                    spp?.stop()
                    spp = SppServer(rx("spp"), conn("spp")).also { it.start() }
                    result.success(null)
                }
                "stopSpp" -> { spp?.stop(); spp = null; result.success(null) }
                "send" -> {
                    val t = call.argument<String>("transport")
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    if (t == "ble") ble?.send(bytes) else spp?.send(bytes)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(args: Any?) { events = null }
        })
    }

    // 注: rx は transport を束縛した関数を返すヘルパ
    private fun rx(transport: String): (ByteArray) -> Unit = { bytes ->
        main.post {
            events?.success(mapOf("type" to "rx", "transport" to transport, "bytes" to bytes.toList()))
        }
    }

    private fun conn(transport: String): (String, String) -> Unit = { state, device ->
        main.post {
            events?.success(mapOf("type" to "conn", "transport" to transport, "state" to state, "device" to device))
        }
    }
}
