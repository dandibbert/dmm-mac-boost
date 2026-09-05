import Cocoa
import WebKit

@MainActor final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(symbol: String, help: String, action: @escaping () -> Void) {
        super.init(frame:.zero)
        image = NSImage(systemSymbolName:symbol,accessibilityDescription:help)
        imagePosition = .imageOnly; bezelStyle = .texturedRounded
        isBordered = false; toolTip = help; setAccessibilityLabel(help)
        target = self; self.action = #selector(invoke); handler = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler?() }
}
@MainActor final class MenuCommand: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
extension NSMenu {
    @MainActor @discardableResult func command(_ title: String,key: String = "",modifiers: NSEvent.ModifierFlags = .command,checked: Bool = false,enabled: Bool = true,action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title:title,action:#selector(MenuCommand.invoke),keyEquivalent:key)
        let target = MenuCommand(action); item.target = target; item.representedObject = target
        item.keyEquivalentModifierMask = modifiers; item.state = checked ? .on : .off; item.isEnabled = enabled
        addItem(item); return item
    }
}
@MainActor func caption(_ text: String,size: CGFloat = 12,secondary: Bool = false) -> NSTextField {
    let view = NSTextField(wrappingLabelWithString:text)
    view.font = .systemFont(ofSize:size); view.textColor = secondary ? .secondaryLabelColor : .labelColor
    return view
}
@MainActor func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
@MainActor func stack(_ views: [NSView],orientation: NSUserInterfaceLayoutOrientation = .vertical,spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views:views); view.orientation = orientation
    view.alignment = orientation == .vertical ? .leading : .centerY; view.spacing = spacing; return view
}
@MainActor class FlippedView: NSView { override var isFlipped: Bool { true } }

// One WebView per running tab. The clip-view bounds transform presentation only;
// the original game, iframe, event handlers and browsing context stay in place.
@MainActor final class PageSurface: FlippedView {
    let plane = NSClipView()
    weak var webView: WKWebView?
    var region: NSRect?
    var logicalSize = NSSize(width:1200,height:760)
    var placeholder: NSView?
    var onResize: (() -> Void)?
    private var arranging = false
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        plane.drawsBackground = false; plane.autoresizesSubviews = false
        addSubview(plane)
    }
    required init?(coder: NSCoder) { fatalError() }
    func attach(_ view: WKWebView) {
        placeholder?.removeFromSuperview(); placeholder = nil
        plane.documentView = nil; webView = view
        view.autoresizingMask = []; plane.documentView = view
        region = nil; needsLayout = true
    }
    func focus(_ rect: NSRect?,viewport: NSSize? = nil) {
        if let rect,rect.width >= 100,rect.height >= 70,rect.minX.isFinite,rect.minY.isFinite {
            if region == nil { logicalSize = viewport ?? webView?.frame.size ?? bounds.size }
            region = rect
        } else { region = nil }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func showPlaceholder(_ view: NSView) {
        placeholder?.removeFromSuperview(); placeholder = view
        addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo:centerXAnchor),view.centerYAnchor.constraint(equalTo:centerYAnchor),view.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-64)])
    }
    override func layout() {
        super.layout()
        guard !arranging,bounds.width > 0,bounds.height > 0 else { return }
        arranging = true; defer { arranging = false }
        if let r = region,r.width > 0,r.height > 0 {
            let scale = min(bounds.width/r.width,bounds.height/r.height)
            let size = NSSize(width:r.width*scale,height:r.height*scale)
            webView?.setFrameSize(logicalSize)
            plane.frame = NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
            plane.setBoundsSize(r.size); plane.setBoundsOrigin(r.origin)
        } else {
            plane.frame = bounds
            plane.setBoundsSize(bounds.size); plane.setBoundsOrigin(.zero)
            webView?.frame = NSRect(origin:.zero,size:bounds.size)
            logicalSize = bounds.size
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize); needsLayout = true
        if changed { onResize?() }
    }
}

@MainActor final class BrowserNativeWindow: NSWindow {
    var steadySessions = 0
    var actuallyVisible: Bool { super.isVisible }
    // WebKit checks both visibility and occlusion, including during miniaturization.
    // These execution signals are held only while this window owns protected tabs.
    // They neither make the window key nor order it in front of other applications.
    override var isVisible: Bool { steadySessions > 0 || super.isVisible }
    override var occlusionState: NSWindow.OcclusionState {
        steadySessions > 0 ? .visible : super.occlusionState
    }
}

@MainActor final class TabChip: FlippedView {
    let tabID: UUID
    let label = NSTextField(labelWithString:"")
    let glyph = NSImageView()
    let close: ActionButton
    var select: (() -> Void)?
    var showMenu: ((NSEvent) -> Void)?
    var startDrag: ((NSEvent) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    init(id: UUID,closeAction: @escaping () -> Void) {
        tabID = id; close = ActionButton(symbol:"xmark",help:"关闭标签页",action:closeAction)
        super.init(frame:NSRect(x:0,y:0,width:180,height:32))
        wantsLayer = true; layer?.cornerRadius = 6
        label.font = .systemFont(ofSize:12); label.lineBreakMode = .byTruncatingTail
        addSubview(glyph); addSubview(label); addSubview(close)
        glyph.frame = NSRect(x:10,y:9,width:14,height:14)
        close.frame = NSRect(x:154,y:5,width:22,height:22); close.autoresizingMask = .minXMargin
        label.frame = NSRect(x:32,y:8,width:118,height:18); label.autoresizingMask = .width
        setAccessibilityElement(true); setAccessibilityRole(.radioButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = (selected ? NSColor.controlBackgroundColor : NSColor.clear).cgColor
        super.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) { select?() }
    override func mouseDragged(with event: NSEvent) { startDrag?(event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { close.handler?() } }
}
