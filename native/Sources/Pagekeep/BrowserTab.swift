import AppKit
import Combine
import WebKit
import BrowserCore
import WebKitBridge

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler {
    nonisolated let id: UUID
    @Published var record: TabRecord
    @Published var webView: WKWebView?
    @Published var progress = 0.0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var focused = false
    @Published var notice: String?
    @Published var crashed = false
    @Published var probeEnabled = false
    @Published var samples: [String: (ProbeSample, Date, Bool)] = [:]
    @Published var policyApplied = false
    @Published var unavailable: [String] = []
    var changed: (() -> Void)?
    var settingsChanged: (() -> Void)?
    var openWindow: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    var closeRequested: (() -> Void)?
    var visited: ((String, String) -> Void)?
    var ruleForURL: ((URL) -> PageRule?)?
    private var observations: [NSKeyValueObservation] = []
    private var frameInfos: [String: WKFrameInfo] = [:]
    private var prefDefaults: [String: Bool] = [:]
    private var occlusionDefault = true
    private var noticeGeneration = UUID()
    init(record: TabRecord, configuration: WKWebViewConfiguration? = nil) {
        var initial = record
        initial.compatibility = false; initial.forceFrames = false
        self.id = initial.id
        self.record = initial
        super.init()
        if configuration != nil || (!record.sleeping && record.url != "about:blank") {
            makeWebView(configuration: configuration)
            if configuration == nil, let url = URL(string: record.url) { webView?.load(URLRequest(url: url)) }
        }
    }
    var title: String { record.title.isEmpty ? (URL(string: record.url)?.host ?? "新标签页") : record.title }
    var running: Bool { webView != nil && !record.sleeping && !crashed }
    var policyJSON: String {
        let object: [String: Any] = ["continuous": record.mode == .continuous, "probe": probeEnabled]
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
    private static let preferenceNames: [(String, String, String)] = [
        ("_hiddenPageDOMTimerThrottlingEnabled", "_setHiddenPageDOMTimerThrottlingEnabled:", "后台计时器"),
        ("_hiddenPageDOMTimerThrottlingAutoIncreases", "_setHiddenPageDOMTimerThrottlingAutoIncreases:", "渐进节流"),
        ("_pageVisibilityBasedProcessSuppressionEnabled", "_setPageVisibilityBasedProcessSuppressionEnabled:", "可见性进程抑制")
    ]
    private func makeWebView(configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = .default() }
        let inherited = config.preferences
        let preferences = WKPreferences()
        preferences.minimumFontSize = inherited.minimumFontSize
        preferences.javaScriptCanOpenWindowsAutomatically = inherited.javaScriptCanOpenWindowsAutomatically
        preferences.isElementFullscreenEnabled = true
        config.preferences = preferences
        config.userContentController = WKUserContentController()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, contentWorld: .defaultClient, name: "pagekeep")
        installScript(on: config.userContentController)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true; view.isInspectable = true
        PKSetBoolean(view.configuration.preferences, "_setDeveloperExtrasEnabled:", true)
        for (getter, _, _) in Self.preferenceNames { if let value = PKGetBoolean(view.configuration.preferences, getter) { prefDefaults[getter] = value.boolValue } }
        occlusionDefault = PKGetBoolean(view, "_windowOcclusionDetectionEnabled")?.boolValue ?? true
        webView = view
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.record.title = view.title ?? ""; self?.changed?() } },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { guard let url = view.url, url.scheme != "file" else { return }; self?.record.url = url.absoluteString; self?.changed?() } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.progress = view.estimatedProgress } },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.loading = view.isLoading } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoForward = view.canGoForward } }
        ]
        applyPolicy()
        if record.muted && !PKMute(view, true) { record.muted = false; showNotice("此系统的页面静音接口不可用。") }
    }
    private func installScript(on controller: WKUserContentController) {
        guard let url = BrowserAssets.url("Runtime", "js"), let source = try? String(contentsOf: url, encoding: .utf8) else { showNotice("缺少检测资源，调度探针不可用。"); return }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source.replacingOccurrences(of: "__CONFIG__", with: policyJSON), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }
    func applyPolicy() {
        guard let view = webView else { changed?(); return }
        policyApplied = false; unavailable = []
        let continuous = record.mode == .continuous
        view.configuration.preferences.inactiveSchedulingPolicy = continuous ? .none : .suspend
        for (getter, setter, label) in Self.preferenceNames {
            if let baseline = prefDefaults[getter] {
                if !PKSetBoolean(view.configuration.preferences, setter, continuous ? false : baseline) { unavailable.append(label) }
            } else { unavailable.append(label) }
        }
        if !PKSetBoolean(view, "_setWindowOcclusionDetectionEnabled:", continuous ? false : occlusionDefault) { unavailable.append("窗口遮挡检测") }
        installScript(on: view.configuration.userContentController)
        let script = "globalThis.__pagekeepConfigure && globalThis.__pagekeepConfigure(\(policyJSON)); true;"
        view.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: nil)
        for (key, frame) in frameInfos where !frame.isMainFrame {
            view.evaluateJavaScript(script, in: frame, in: .defaultClient) { [weak self] result in if case .failure = result { self?.frameInfos.removeValue(forKey: key) } }
        }
        changed?()
    }
    func setMode(_ mode: RunMode) { record.mode = mode; settingsChanged?(); applyPolicy() }
    func setAutoFocus(_ value: Bool) {
        record.autoFocus = value; settingsChanged?()
        if value { NativeFocus.shared.perform("auto", tab: self) } else { focus("off") }
    }
    func setProbe(_ value: Bool) { probeEnabled = value; if value { samples.removeAll() }; applyPolicy() }
    func focus(_ action: String) {
        guard ["on", "off", "pick"].contains(action) else { return }
        if action == "off" { record.autoFocus = false; settingsChanged?(); changed?() }
        NativeFocus.shared.perform(action, tab: self)
    }
    func toggleMute() {
        guard let view = webView else { return }
        if PKMute(view, !record.muted) { record.muted.toggle(); changed?() } else { showNotice("此系统的页面静音接口不可用。") }
    }
    func inspect(_ action: String = "show") {
        guard let view = webView else { return }
        if !PKInspector(view, action) { showNotice("内置检查器不可用。可在 Safari 的“开发”菜单中选择 Pagekeep 的页面。") }
    }
    func applyRule(for url: URL) {
        let rule = ruleForURL?(url)
        record.mode = rule?.mode ?? (Address.isDMM(url) ? .continuous : .eco)
        record.autoFocus = rule?.autoFocus ?? Address.isDMM(url)
        record.compatibility = false; record.forceFrames = false
    }
    func navigate(_ url: URL) {
        record.sleeping = false; crashed = false
        if Address.pageKey(URL(string: record.url)) != Address.pageKey(url) || Address.originKey(URL(string: record.url)) != Address.originKey(url) { applyRule(for: url) }
        record.url = url.absoluteString
        if webView == nil { makeWebView() } else { applyPolicy() }
        webView?.load(URLRequest(url: url)); changed?()
    }
    func loadTestPage() {
        record.title = "后台运行测试"; record.mode = .continuous; record.sleeping = false
        if webView == nil { makeWebView() }
        guard let url = BrowserAssets.url("Diagnostics", "html"), let html = try? String(contentsOf: url) else { return }
        webView?.loadHTMLString(html, baseURL: nil); setProbe(true)
    }
    func reload(bypassCache: Bool = false) {
        crashed = false
        if record.sleeping || webView == nil { if let url = URL(string: record.url) { navigate(url) }; return }
        if bypassCache { webView?.reloadFromOrigin() } else { webView?.reload() }
    }
    func prepareForNavigation() {
        frameInfos.removeAll(); samples.removeAll(); focused = false; policyApplied = false; crashed = false
        if let view = webView { NativeFocus.shared.remove(view) }
    }
    func sleep() { guard webView != nil else { return }; record.sleeping = true; dispose(); changed?() }
    func dispose() {
        probeEnabled = false; frameInfos.removeAll(); observations.removeAll(); samples.removeAll()
        if let view = webView {
            NativeFocus.shared.remove(view); PKInspector(view, "close"); view.stopLoading()
            view.navigationDelegate = nil; view.uiDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "pagekeep", contentWorld: .defaultClient)
            view.configuration.userContentController.removeAllUserScripts(); view.removeFromSuperview()
        }
        webView = nil; focused = false; policyApplied = false
    }
    func showNotice(_ message: String) {
        notice = String(message.prefix(500)); let generation = UUID(); noticeGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.noticeGeneration == generation { self?.notice = nil } }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, let key = body["frameID"] as? String, key.count < 100 else { return }
        if frameInfos.count < 64 || frameInfos[key] != nil { frameInfos[key] = message.frameInfo }
        switch kind {
        case "ready":
            webView?.evaluateJavaScript("globalThis.__pagekeepConfigure && globalThis.__pagekeepConfigure(\(policyJSON)); true;", in: message.frameInfo, in: .defaultClient, completionHandler: nil)
            if message.frameInfo.isMainFrame && record.autoFocus { NativeFocus.shared.perform("auto", tab: self) }
        case "applied":
            if message.frameInfo.isMainFrame { policyApplied = (body["continuous"] as? Bool) == (record.mode == .continuous) }
        case "probe":
            guard probeEnabled, let elapsed = body["elapsed"] as? Double, elapsed.isFinite, let ticks = body["ticks"] as? Int,
                  let frames = body["frames"] as? Int, let gap = body["gap"] as? Double, gap.isFinite else { return }
            let label = message.frameInfo.isMainFrame ? "主页面" : "子框架 \(key.prefix(6))"
            if samples.count < 64 || samples[label] != nil { samples[label] = (ProbeSample(elapsed: elapsed, ticks: ticks, frames: frames, largestGap: gap), Date(), body["realHidden"] as? Bool ?? false) }
        default: break
        }
    }
}
