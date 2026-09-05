import AppKit
import Combine
import WebKit

@MainActor
final class NativeFocus: ObservableObject {
    struct Region { let rect: CGRect; let viewport: CGSize; let label: String }
    static let shared = NativeFocus()
    @Published private(set) var regions: [ObjectIdentifier: Region] = [:]
    private var requests: [ObjectIdentifier: UUID] = [:]
    func remove(_ web: WKWebView) { let id = ObjectIdentifier(web); requests.removeValue(forKey: id); regions.removeValue(forKey: id) }
    func perform(_ action: String, tab: BrowserTab) {
        guard let web = tab.webView else { return }
        let id = ObjectIdentifier(web)
        if action == "off" { remove(web); tab.focused = false; return }
        if action == "auto" && (!tab.record.autoFocus || regions[id] != nil) { return }
        let request = UUID(); requests[id] = request
        let sourceURL = web.url
        // Geometry is read in an isolated world. The game DOM and its APIs are not modified.
        let script = """
        (() => {
          const items = [...document.querySelectorAll('iframe,canvas')].map(node => {
            const r = node.getBoundingClientRect(), style = getComputedStyle(node);
            const hint = [node.id, node.className, node.getAttribute('src') || ''].join(' ').toLowerCase();
            if (r.width < 240 || r.height < 150 || r.width > 8192 || r.height > 8192 || r.x < -1 || r.y < -1 || style.display === 'none' || style.visibility === 'hidden') return null;
            if (/captcha|doubleclick|advert|banner|login|payment|checkout|youtube/.test(hint)) return null;
            const score = Math.min(1, r.width*r.height / Math.max(1, innerWidth*innerHeight)) + (/game|canvas|unity|webgl|appframe/.test(hint) ? 0.65 : 0);
            return {x:r.x,y:r.y,width:r.width,height:r.height,score,label:(node.title || node.id || node.tagName).slice(0,120)};
          }).filter(Boolean).sort((a,b)=>b.score-a.score);
          return {width:innerWidth,height:innerHeight,items:items.slice(0,20)};
        })()
        """
        web.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak tab, weak web] result in
            guard let self, let tab, let web, tab.webView === web, web.url == sourceURL, self.requests[id] == request else { return }
            guard case .success(let payload) = result, let data = payload as? [String: Any],
                  let width = data["width"] as? Double, width > 0, let raw = data["items"] as? [[String: Any]] else {
                if action != "auto" { tab.showNotice("暂时无法读取页面布局，请在页面加载完成后重试。") }; return
            }
            let unit = web.bounds.width / width
            let candidates: [(Region, Double)] = raw.compactMap { value in
                guard let x = value["x"] as? Double, let y = value["y"] as? Double,
                      let w = value["width"] as? Double, let h = value["height"] as? Double, let score = value["score"] as? Double else { return nil }
                let rect = CGRect(x: max(0,x)*unit, y: max(0,y)*unit, width: w*unit, height: h*unit)
                let viewport = CGSize(width: max(web.bounds.width, rect.maxX), height: max(web.bounds.height, rect.maxY))
                return (Region(rect: rect, viewport: viewport, label: value["label"] as? String ?? "游戏区域"), score)
            }
            guard let first = candidates.first else { if action != "auto" { tab.showNotice("未找到可专注的游戏区域。请滚动到游戏所在位置后重试。") }; return }
            let choose: (Region) -> Void = { [weak self, weak tab, weak web] region in
                guard let self, let tab, let web, tab.webView === web, self.requests[id] == request else { return }
                self.regions[id] = region; tab.focused = true
            }
            if action == "pick" {
                let alert = NSAlert(); alert.messageText = "选择游戏区域"
                alert.informativeText = "仅裁切显示区域，不重新加载或移动网页中的游戏。"
                let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
                choices.addItems(withTitles: candidates.map { "\($0.0.label) · \(Int($0.0.rect.width)) × \(Int($0.0.rect.height))" })
                alert.accessoryView = choices; alert.addButton(withTitle: "专注"); alert.addButton(withTitle: "取消")
                let finish: (NSApplication.ModalResponse) -> Void = { answer in
                    if answer == .alertFirstButtonReturn, candidates.indices.contains(choices.indexOfSelectedItem) { choose(candidates[choices.indexOfSelectedItem].0) }
                }
                if let window = tab.presentationWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
            } else if first.1 >= 0.65 && (candidates.count == 1 || first.1 - candidates[1].1 >= 0.12) { choose(first.0) }
            else if action != "auto" { tab.showNotice("存在多个可能的游戏区域，请使用“选择游戏区域”。") }
        }
    }
}

@MainActor final class GameClipView: NSView {
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
}
@MainActor final class NativeGameView: NSView {
    private let clip = GameClipView()
    private var web: WKWebView?
    var region: NativeFocus.Region? { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; clip.wantsLayer = true; clip.layer?.masksToBounds = true; addSubview(clip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func connect(_ view: WKWebView) {
        BackgroundRenderer.shared.bind(view, to: self)
        attach(view)
    }
    func attach(_ view: WKWebView) {
        guard web !== view || view.superview !== clip else { return }
        if let old = web, old !== view, old.superview === clip { old.removeFromSuperview() }
        web = view; view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true; view.autoresizingMask = []
        clip.addSubview(view); needsLayout = true
    }
    func detach() {
        guard let old = web else { return }
        if old.superview === clip { old.removeFromSuperview() }
        web = nil; BackgroundRenderer.shared.unbind(old, from: self)
    }
    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let web, web.superview === clip, bounds.width > 0, bounds.height > 0 else { return }
        if let region, region.rect.width > 0, region.rect.height > 0 {
            let scale = min(bounds.width / region.rect.width, bounds.height / region.rect.height)
            let size = CGSize(width: region.rect.width * scale, height: region.rect.height * scale)
            clip.frame = CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
            clip.bounds = region.rect
            web.frame = CGRect(origin: .zero, size: region.viewport)
        } else {
            clip.frame = bounds; clip.bounds = CGRect(origin: .zero, size: bounds.size)
            web.frame = clip.bounds
        }
    }
}
