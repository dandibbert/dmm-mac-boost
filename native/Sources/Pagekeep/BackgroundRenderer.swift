import AppKit
import Combine
import WebKit

@MainActor
private final class RenderingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class BackgroundRenderer {
    static let shared = BackgroundRenderer()
    private final class WeakHost {
        weak var value: NativeGameView?
        init(_ value: NativeGameView) { self.value = value }
    }
    private var hosts: [ObjectIdentifier: WeakHost] = [:]
    private var parked: [ObjectIdentifier: WKWebView] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    private var updating = false
    private let panel: RenderingPanel
    private let canvas = NSView()

    private init() {
        panel = RenderingPanel(contentRect: NSRect(x: 20000, y: 20000, width: 1280, height: 800),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pagekeep Background Rendering"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentView = canvas
        panel.setAccessibilityElement(false)
        let names: [Notification.Name] = [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                                         NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                         NSApplication.didChangeScreenParametersNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        }
    }
    func bind(_ web: WKWebView, to host: NativeGameView) {
        hosts[ObjectIdentifier(web)] = WeakHost(host)
        schedule()
    }
    func unbind(_ web: WKWebView, from host: NativeGameView) {
        let key = ObjectIdentifier(web)
        if hosts[key]?.value === host { hosts.removeValue(forKey: key) }
        schedule()
    }
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.update() }
    }
    private func update() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let browsers = AppDelegate.shared?.windows ?? []
        var retainedSubscriptions = Set<String>()
        var desired: [ObjectIdentifier: WKWebView] = [:]
        var foreground: [(WKWebView, NativeGameView)] = []
        for browser in browsers {
            let modelKey = "window-" + String(describing: ObjectIdentifier(browser.model))
            retainedSubscriptions.insert(modelKey)
            if subscriptions[modelKey] == nil {
                subscriptions[modelKey] = browser.model.objectWillChange.sink { [weak self] _ in self?.schedule() }
            }
            for tab in browser.model.tabs {
                let tabKey = "tab-" + tab.id.uuidString
                retainedSubscriptions.insert(tabKey)
                if subscriptions[tabKey] == nil { subscriptions[tabKey] = tab.objectWillChange.sink { [weak self] _ in self?.schedule() } }
                guard let web = tab.webView, tab.running else { continue }
                let key = ObjectIdentifier(web)
                let windowAvailable = browser.window?.isVisible == true && browser.window?.isMiniaturized == false && !NSApp.isHidden
                let isSelected = browser.model.active?.id == tab.id
                if tab.record.mode == .continuous && (!isSelected || !windowAvailable) {
                    desired[key] = web
                } else if isSelected, windowAvailable, let host = hosts[key]?.value {
                    foreground.append((web, host))
                }
            }
        }
        for key in subscriptions.keys.filter({ !retainedSubscriptions.contains($0) }) { subscriptions.removeValue(forKey: key) }
        for (key, web) in parked where desired[key] == nil {
            if web.superview === canvas { web.removeFromSuperview() }
        }
        parked = desired
        for (web, host) in foreground { host.attach(web) }
        if desired.isEmpty { if panel.isVisible { panel.orderOut(nil) }; return }
        var size = NSSize(width: 1280, height: 800)
        for web in desired.values {
            size.width = max(size.width, web.bounds.width)
            size.height = max(size.height, web.bounds.height)
        }
        // An ordered native window keeps WebKit's view lifecycle active. It remains
        // beyond all displays, never takes keyboard focus and never receives input.
        let right = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
        let top = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let frame = NSRect(x: right + 10000, y: top + 10000, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        for web in desired.values where web.superview !== canvas {
            var viewport = web.bounds.size
            if viewport.width < 1 || viewport.height < 1 { viewport = NSSize(width: 1280, height: 800) }
            web.removeFromSuperview(); web.translatesAutoresizingMaskIntoConstraints = true; web.autoresizingMask = []
            web.frame = NSRect(origin: .zero, size: viewport)
            canvas.addSubview(web)
        }
        if !panel.isVisible { panel.orderBack(nil) }
    }
}
