import Cocoa
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// A display is active when connected, awake, and drawable. An asleep
    /// display (lid closed with an external display attached, or display
    /// sleep) can still appear in `NSScreen.screens` and remain part of the
    /// desktop space, but is not drawable — it must not get a wallpaper
    /// window.
    var isActive: Bool {
        CGDisplayIsActive(displayID) != 0
    }
}
