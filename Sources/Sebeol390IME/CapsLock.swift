import IOKit
import IOKit.hidsystem

enum CapsLockReset {
    /// Caps Lock is the 한/영 key. Turn the LED back off so the next press
    /// toggles again and letters are not stuck capitalized.
    static func turnOff() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard opened == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    }
}
