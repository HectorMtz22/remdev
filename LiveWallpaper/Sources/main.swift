import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
// withExtendedLifetime prevents -O from releasing the delegate early.
// NSApplication.delegate is weak, so without this the optimizer can free
// the AppDelegate after assignment, leaving autoreleased objects dangling.
withExtendedLifetime(delegate) {
    app.run()
}
