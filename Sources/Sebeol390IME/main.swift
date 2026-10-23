import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

private let bundleIdentifier = "com.sebeol390.inputmethod.Sebeol390"
private let connectionName = bundleIdentifier + "_Connection"

if CommandLine.arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    fputs("TISRegisterInputSource status \(status)\n", stderr)
    if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
        for source in list {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if value == bundleIdentifier {
                let enable = TISEnableInputSource(source)
                fputs("TISEnableInputSource status \(enable)\n", stderr)
            }
        }
    }
    exit(status == noErr ? 0 : 1)
}

private let server: IMKServer = {
    guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
        fputs("IMKServer를 시작하지 못했습니다.\n", stderr)
        exit(1)
    }
    return server
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
withExtendedLifetime(server) {
    app.run()
}
