import CoreBluetooth
import Foundation

class BleGattServer: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private var notifyChar: CBMutableCharacteristic?
    private var central: CBCentral?
    private let onRx: (Data) -> Void
    private let onConn: (String, String) -> Void
    private var useFff0 = false
    private var pendingStart = false
    private var pending: [Data] = []

    init(onRx: @escaping (Data) -> Void, onConn: @escaping (String, String) -> Void) {
        self.onRx = onRx
        self.onConn = onConn
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    private func svcUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF0" : "FFE0") }
    private func writeUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF2" : "FFE1") }
    private func notifyUuid() -> CBUUID { CBUUID(string: useFff0 ? "FFF1" : "FFE1") }

    func start(useFff0: Bool) {
        self.useFff0 = useFff0
        pendingStart = true
        if manager.state == .poweredOn { setup() }
    }

    private func setup() {
        pendingStart = false
        let service = CBMutableService(type: svcUuid(), primary: true)

        if useFff0 {
            // FFF0: separate notify (FFF1) and write (FFF2) characteristics
            let notifyC = CBMutableCharacteristic(
                type: notifyUuid(),
                properties: [.notify],
                value: nil,
                permissions: [.readable])
            let writeC = CBMutableCharacteristic(
                type: writeUuid(),
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable])
            service.characteristics = [notifyC, writeC]
            notifyChar = notifyC
        } else {
            // FFE0: single characteristic FFE1 carrying write + notify (write UUID == notify UUID)
            let combined = CBMutableCharacteristic(
                type: notifyUuid(),
                properties: [.write, .writeWithoutResponse, .notify],
                value: nil,
                permissions: [.writeable, .readable])
            service.characteristics = [combined]
            notifyChar = combined
        }

        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [svcUuid()],
            CBAdvertisementDataLocalNameKey: "OBDII",
        ])
    }

    func send(_ data: Data) {
        var i = 0
        let chunkSize = 20
        while i < data.count {
            let end = min(i + chunkSize, data.count)
            pending.append(data.subdata(in: i..<end))
            i = end
        }
        flushPending()
    }

    private func flushPending() {
        guard let ch = notifyChar else { return }
        while !pending.isEmpty {
            let chunk = pending[0]
            let ok = manager.updateValue(chunk, for: ch, onSubscribedCentrals: nil)
            if ok {
                pending.removeFirst()
            } else {
                break // CoreBluetooth will call peripheralManagerIsReady(toUpdateSubscribers:)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPending()
    }

    func stop() {
        manager.stopAdvertising()
        manager.removeAllServices()
        notifyChar = nil
        central = nil
        pending = []
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn && pendingStart { setup() }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let v = req.value { onRx(v) }
            p.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo ch: CBCharacteristic) {
        self.central = central
        onConn("connected", central.identifier.uuidString)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom ch: CBCharacteristic) {
        onConn("disconnected", central.identifier.uuidString)
    }
}
