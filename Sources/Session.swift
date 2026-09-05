import Cocoa
import WebKit

@MainActor enum RuntimeEnvironment {
    static var testing = false
    static func resource(_ name: String, extension ext: String) -> String {
        guard let url = Bundle.main.url(forResource:name,withExtension:ext), let text = try? String(contentsOf:url,encoding:.utf8) else { return "" }
        return text
    }
    static let probe = resource("Runtime", extension:"js")
    static let viewport = resource("Viewport", extension:"js")
}
@MainActor final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { tab?.receive(message) }
}
@MainActor final class BrowserTab: NSObject {
    var record: TabRecord
    weak var owner: BrowserWindow?
    private(set) var webView: WKWebView?
    let surface = PageSurface(frame:NSRect(x:0,y:0,width:1200,height:760))
    var frames: [String: WKFrameInfo] = [:]
    var capabilities: [String: NSNumber] = [:]
    var observations: [NSKeyValueObservation] = []
    var diagnosing = false
    var failure: String?
    var documentGeneration = 0
    var focusRequest = 0
    var lastProfileKey: String?
    var lastLoadedAt = Date()
    var isClosed = false
    var id: UUID { record.id }
    var url: URL? { record.url.isEmpty ? nil : URL(string:record.url) }
    var isSteady: Bool { !record.sleeping && !isClosed && webView != nil && record.preferences.mode == .steady }
    var focused: Bool { surface.region != nil }
    var policyJSON: String { jsonString(["steady":record.preferences.mode == .steady,"frames":false,"visibility":false,"diagnose":diagnosing]) }

    init(record: TabRecord = TabRecord(), configuration: WKWebViewConfiguration? = nil, load: Bool = true) {
        self.record = record; super.init()
        surface.autoresizingMask = [.width,.height]
        if !record.sleeping {
            createView(configuration:configuration)
            if load, let url { webView?.load(URLRequest(url:url)) }
        }
        surface.onResize = { [weak self] in
            guard let self, self.record.preferences.autoFocus, !self.focused else { return }
            self.scheduleFocus(attempts:2)
        }
    }
    func createView(configuration supplied: WKWebViewConfiguration? = nil) {
        guard webView == nil else { return }
        let configuration = supplied ?? WKWebViewConfiguration()
        if supplied == nil { configuration.websiteDataStore = RuntimeEnvironment.testing ? .nonPersistent() : .default() }
        // Never share mutable per-tab preferences or message handlers with a popup.
        configuration.preferences = WKPreferences()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = record.preferences.allowPopups
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.add(WeakMessageHandler(self), name:"stillRuntime")
        installScripts(on:configuration.userContentController)
        let view = WKWebView(frame:surface.bounds,configuration:configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true; view.isInspectable = true
        view.pageZoom = record.preferences.zoom
        webView = view; surface.attach(view)
        observations = [
            view.observe(\.title,options:[.new]) { [weak self] _,_ in self?.changed() },
            view.observe(\.url,options:[.new]) { [weak self] _,_ in self?.changed() },
            view.observe(\.isLoading,options:[.new]) { [weak self] _,_ in self?.changed() },
            view.observe(\.estimatedProgress,options:[.new]) { [weak self] _,_ in self?.owner?.refreshChrome() },
            view.observe(\.canGoBack,options:[.new]) { [weak self] _,_ in self?.owner?.refreshChrome() },
            view.observe(\.canGoForward,options:[.new]) { [weak self] _,_ in self?.owner?.refreshChrome() }
        ]
        applyPolicy(persist:false)
    }
    func installScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let script = RuntimeEnvironment.probe.replacingOccurrences(of:"__STILL_POLICY__",with:policyJSON)
        controller.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:false))
    }
    func changed() {
        guard !isClosed else { return }
        if let view = webView {
            if let value = view.url, value.absoluteString != "about:blank" { record.url = value.absoluteString }
            if let title = view.title, !title.isEmpty { record.title = title }
        }
        owner?.tabDidChange(self)
    }
    func navigate(to url: URL) {
        if record.sleeping { record.sleeping = false; createView() }
        record.url = url.absoluteString
        record.preferences = BrowserStore.shared.preferences(for:url)
        lastProfileKey = Address.gameKey(url)
        failure = nil; surface.placeholder?.removeFromSuperview(); surface.placeholder = nil
        surface.focus(nil); applyPolicy(persist:false)
        if url.isFileURL { webView?.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
        else { webView?.load(URLRequest(url:url)) }
        changed()
    }
    func applyPolicy(persist: Bool = true) {
        guard let view = webView else { return }
        capabilities = STApplyPolicy(view,record.preferences.mode == .steady)
        if !STSetMuted(view,record.preferences.mute), record.preferences.mute { failure = "此系统未提供标签静音接口。" }
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = record.preferences.allowPopups
        view.pageZoom = record.preferences.zoom
        installScripts(on:view.configuration.userContentController)
        let source = "globalThis.__stillRuntime?.setPolicy(\(policyJSON));"
        view.evaluateJavaScript(source,completionHandler:nil)
        for frame in frames.values where !frame.isMainFrame {
            view.evaluateJavaScript(source,in:frame,in:.page,completionHandler:{ _ in })
        }
        if !record.preferences.autoFocus { surface.focus(nil) }
        else { scheduleFocus(attempts:4) }
        if persist { BrowserStore.shared.savePreferences(record.preferences,for:url) }
        owner?.tabDidChange(self)
        (NSApp.delegate as? AppDelegate)?.sessionsChanged()
    }
    func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, let body = message.body as? [String:Any], let token = body["token"] as? String, token.count < 100 else { return }
        if body["type"] as? String == "ready" {
            if frames.count >= 64 { frames.removeAll(keepingCapacity:true) }
            frames[token] = message.frameInfo
            webView?.evaluateJavaScript("globalThis.__stillRuntime?.setPolicy(\(policyJSON));",in:message.frameInfo,in:.page,completionHandler:{ _ in })
        }
    }
    func setMode(_ mode: RunMode) { record.preferences.mode = mode; applyPolicy() }
    func setMuted(_ muted: Bool) {
        guard let view = webView, STSetMuted(view,muted) else { owner?.notice("此系统未提供原生标签静音接口。",detail:"没有暂停游戏或用不完整的媒体脚本代替静音。"); return }
        record.preferences.mute = muted; applyPolicy()
    }
    func scheduleFocus(attempts: Int = 8) {
        focusRequest += 1; let ticket = focusRequest
        func attempt(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.65) { [weak self] in
                guard let self, !self.isClosed, self.focusRequest == ticket, self.record.preferences.autoFocus, let view = self.webView else { return }
                view.evaluateJavaScript(RuntimeEnvironment.viewport,in:nil,in:.defaultClient) { [weak self] result in
                    guard let self, self.focusRequest == ticket else { return }
                    if case .success(let value) = result, let region = value as? [String:Double], let x = region["x"], let y = region["y"], let width = region["width"], let height = region["height"], x >= 0, y >= 0 {
                        self.surface.focus(NSRect(x:x,y:y,width:width,height:height),viewport:NSSize(width:region["viewportWidth"] ?? 1200,height:region["viewportHeight"] ?? 760))
                        self.owner?.refreshChrome()
                    } else if remaining > 1 { attempt(remaining-1) }
                }
            }
        }
        attempt(attempts)
    }
    func toggleFocus() {
        if focused || record.preferences.autoFocus {
            focusRequest += 1; record.preferences.autoFocus = false; surface.focus(nil)
        } else { record.preferences.autoFocus = true; scheduleFocus(attempts:8) }
        BrowserStore.shared.savePreferences(record.preferences,for:url); owner?.refreshChrome()
    }
    func sleep() {
        record.sleeping = true; destroyView(); owner?.showPlaceholder(for:self); changed()
        (NSApp.delegate as? AppDelegate)?.sessionsChanged()
    }
    func wake() {
        record.sleeping = false; createView()
        if let url { webView?.load(URLRequest(url:url)) }
        owner?.tabDidChange(self)
    }
    func destroyView() {
        focusRequest += 1; diagnosing = false; observations.removeAll(); frames.removeAll()
        if let view = webView {
            view.navigationDelegate = nil; view.uiDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName:"stillRuntime")
            STCloseWebView(view); view.removeFromSuperview()
        }
        webView = nil; surface.focus(nil)
    }
    func close() { isClosed = true; destroyView(); surface.removeFromSuperview() }
    func showFailure(_ message: String) {
        failure = message; surface.focus(nil)
        owner?.showPlaceholder(for:self); owner?.refreshChrome()
    }
    func inspect(_ command: String = "show") {
        guard let view = webView else { return }
        if !STInspector(view,command) { owner?.notice("无法打开内置开发者工具",detail:"本系统不提供所需接口。此页面仍允许从 Safari 的“开发”菜单检查。"); }
    }
}
