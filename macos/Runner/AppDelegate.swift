import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    let plugin = Elm327Plugin()

    override func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
        plugin.register(messenger: controller.engine.binaryMessenger)
        super.applicationDidFinishLaunching(notification)
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
