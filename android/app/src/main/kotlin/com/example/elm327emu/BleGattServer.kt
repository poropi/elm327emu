package com.example.elm327emu

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import java.util.UUID

class BleGattServer(
    private val context: Context,
    private val onRx: (ByteArray) -> Unit,
    private val onConn: (String, String) -> Unit,
) {
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    @Volatile private var device: BluetoothDevice? = null

    fun start(useFff0: Boolean) {
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = mgr.adapter
        adapter.name = "OBDII"

        val serviceUuid = uuid(if (useFff0) "FFF0" else "FFE0")
        val writeUuid = uuid(if (useFff0) "FFF2" else "FFE1")
        val notifyUuid = uuid(if (useFff0) "FFF1" else "FFE1")

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val writeProps = BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
        val notifyProp = BluetoothGattCharacteristic.PROPERTY_NOTIFY
        val cccd = { BluetoothGattDescriptor(uuid("2902"), BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE) }

        if (notifyUuid == writeUuid) {
            // FFE0 profile: single characteristic handles both WRITE and NOTIFY
            notifyChar = BluetoothGattCharacteristic(writeUuid, writeProps or notifyProp, BluetoothGattCharacteristic.PERMISSION_WRITE).also { it.addDescriptor(cccd()) }
            service.addCharacteristic(notifyChar)
        } else {
            // FFF0 profile: separate write (FFF2) and notify (FFF1) characteristics
            val writeChar = BluetoothGattCharacteristic(writeUuid, writeProps, BluetoothGattCharacteristic.PERMISSION_WRITE)
            notifyChar = BluetoothGattCharacteristic(notifyUuid, notifyProp, BluetoothGattCharacteristic.PERMISSION_READ).also { it.addDescriptor(cccd()) }
            service.addCharacteristic(writeChar)
            service.addCharacteristic(notifyChar)
        }

        advertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()

        gattServer = mgr.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    advertiser?.startAdvertising(settings, data, object : AdvertiseCallback() {})
                }
            }

            override fun onConnectionStateChange(d: BluetoothDevice, status: Int, newState: Int) {
                device = if (newState == BluetoothProfile.STATE_CONNECTED) d else null
                onConn(if (newState == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected", d.address ?: "")
            }

            override fun onCharacteristicWriteRequest(
                d: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
            ) {
                onRx(value)
                if (responseNeeded) {
                    gattServer?.sendResponse(d, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }

            override fun onDescriptorWriteRequest(
                d: BluetoothDevice, requestId: Int, desc: BluetoothGattDescriptor,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
            ) {
                if (responseNeeded) {
                    gattServer?.sendResponse(d, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }
        })
        gattServer?.addService(service)
    }

    /** 応答を MTU(20) ごとに分割 Notify する。 */
    fun send(bytes: ByteArray) {
        val ch = notifyChar ?: return
        val d = device ?: return
        var i = 0
        while (i < bytes.size) {
            val end = minOf(i + 20, bytes.size)
            ch.value = bytes.copyOfRange(i, end)
            gattServer?.notifyCharacteristicChanged(d, ch, false)
            i = end
        }
    }

    fun stop() {
        advertiser?.stopAdvertising(object : AdvertiseCallback() {})
        gattServer?.close()
        gattServer = null
    }

    private fun uuid(short: String): UUID =
        if (short.length <= 4)
            UUID.fromString("0000$short-0000-1000-8000-00805F9B34FB")
        else UUID.fromString(short)
}
