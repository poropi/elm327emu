import FlutterMacOS
import Foundation

class Elm327Plugin: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var ble: BleGattServer?

    func register(messenger: FlutterBinaryMessenger) {
        let control = FlutterMethodChannel(name: "elm327/control", binaryMessenger: messenger)
        let events = FlutterEventChannel(name: "elm327/events", binaryMessenger: messenger)
        events.setStreamHandler(self)
        control.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "capabilities":
                result(["ble"])
            case "startBle":
                let args = call.arguments as? [String: Any]
                let fff0 = (args?["profile"] as? String) == "fff0"
                self.ble?.stop()
                self.ble = BleGattServer(
                    onRx: { data in self.emitRx(Array(data)) },
                    onConn: { s, d in self.emitConn(s, d) })
                self.ble?.start(useFff0: fff0)
                result(nil)
            case "stopBle":
                self.ble?.stop()
                self.ble = nil
                result(nil)
            case "startSpp", "stopSpp":
                result(FlutterError(code: "unsupported",
                                    message: "SPP not supported on macOS",
                                    details: nil))
            case "send":
                let args = call.arguments as? [String: Any]
                if let data = args?["bytes"] as? FlutterStandardTypedData {
                    self.ble?.send(data.data)
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func emitRx(_ bytes: [UInt8]) {
        DispatchQueue.main.async {
            self.sink?(["type": "rx", "transport": "ble", "bytes": bytes.map { Int($0) }])
        }
    }

    private func emitConn(_ state: String, _ device: String) {
        DispatchQueue.main.async {
            self.sink?(["type": "conn", "transport": "ble", "state": state, "device": device])
        }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
