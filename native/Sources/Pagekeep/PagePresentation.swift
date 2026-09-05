import AppKit

extension BrowserTab {
    /// Browser dialogs belong to the user-facing window, not to an internal rendering surface.
    var presentationWindow: NSWindow? {
        AppDelegate.shared?.windows.first(where: { browser in
            browser.model.tabs.contains(where: { $0.id == id })
        })?.window
    }
}
