import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches the system power domain (IORegisterForSystemPower, Apple QA1340) and
/// reports forced sleep / wake — the reliable signal for lid-close sleep, which
/// the NSWorkspace screens-sleep notification does not guarantee.
///
/// The IOKit callbacks arrive on this run loop (the main loop), same pattern as
/// PowerManager's IOPSNotificationCreateRunLoopSource. On registration failure
/// the app degrades gracefully: the NSWorkspace signals still cover sleep/wake.
protocol SystemSleepMonitorDelegate: AnyObject {
    func systemSleepMonitorDidSleep()
    func systemSleepMonitorDidWake()
}

// The IOMessage.h macros (iokit_common_msg arithmetic) don't import into Swift,
// so reproduce the values: sys_iokit | sub_iokit_common | message
// = (0x38 << 26) | 0 | message.
private let kSystemWillSleepMessage: natural_t = 0xE0000280     // kIOMessageSystemWillSleep
private let kSystemHasPoweredOnMessage: natural_t = 0xE0000300 // kIOMessageSystemHasPoweredOn

class SystemSleepMonitor {
    weak var delegate: SystemSleepMonitorDelegate?

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        // IORegisterForSystemPower RETURNS the root-port handle (0 = failure);
        // the 4th out-param receives the notifier object (QA1340).
        let newRootPort = IORegisterForSystemPower(context, &notificationPort, Self.callback, &notifier)
        guard newRootPort != 0, let notificationPort else {
            NSLog("SystemSleepMonitor: IORegisterForSystemPower failed; falling back to NSWorkspace sleep signals")
            return
        }
        rootPort = newRootPort
        runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }

    private static let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard let refcon else { return }
        let monitor = Unmanaged<SystemSleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
        // Swift imports the C `void *messageArgument` param as a raw pointer;
        // the real value is the integer it wraps.
        let argument = natural_t(UInt(bitPattern: messageArgument))
        monitor.handleMessage(messageType, messageArgument: argument)
    }

    private func handleMessage(_ messageType: natural_t, messageArgument: natural_t) {
        switch messageType {
        case kSystemWillSleepMessage:
            delegate?.systemSleepMonitorDidSleep()
            // Acknowledge immediately so the system doesn't wait ~30s before
            // sleeping (QA1340). Delivered last — this call can put the
            // machine to sleep before the delegate's teardown finishes.
            IOAllowPowerChange(rootPort, Int(messageArgument))
        case kSystemHasPoweredOnMessage:
            delegate?.systemSleepMonitorDidWake()
        default:
            // kIOMessageCanSystemSleep etc. — no veto, no acknowledgement needed
            break
        }
    }
}
