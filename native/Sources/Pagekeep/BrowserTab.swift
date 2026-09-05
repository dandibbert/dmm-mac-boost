import AppKit
import Combine
import WebKit
import BrowserCore
import WebKitBridge

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var id: UUID { record.id }
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
        self.record = record
        super.init()
        if configuration != nil || (!record.sleeping && record.url != "about:blank") {
            makeWebView(configuration: configuration)
            if configuration == nil, let url = URL(string: record.url) { webView?.load(URLRequest(url: url)) }
        }
    }
    var title: String { record.title.isEmpty ? (URL(string: record.url)?.host ?? "新标签页") : record.title }
    var running: Bool { webView != nil && !record.sleeping && !crashed }
    var policyJSON: String {
        let object: [String: Any] = ["continuous": record.mode == .continuous, "compatibility": record.compatibility,
                                   "forceFrames": record.forceFrames, "autoFocus": record.autoFocus, "probe": probeEnabled]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
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
        // Retain WebKit's supplied window.open configuration, including its opener relationship.
        if let preferences = config.preferences.copy() as? WKPreferences { config.preferences = preferences }
        config.userContentController = WKUserContentController()
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "pagekeep")
        installScript(on: config.userContentController)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        PKSetBoolean(view.configuration.preferences, "_setDeveloperExtrasEnabled:", true)
        for (getter, _, _) in Self.preferenceNames {
            if let value = PKGetBoolean(view.configuration.preferences, getter) { prefDefaults[getter] = value.boolValue }
        }
        occlusionDefault = PKGetBoolean(view, "_windowOcclusionDetectionEnabled")?.boolValue ?? true
        webView = view
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { guard let self else { return }; self.record.title = view.title ?? ""; self.changed?() }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { guard let self, let url = view.url, url.scheme != "file" else { return }; self.record.url = url.absoluteString; self.changed?() }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.progress = view.estimatedProgress } },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.loading = view.isLoading } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoForward = view.canGoForward } }
        ]
        applyPolicy()
        if record.muted && !PKMute(view, true) { record.muted = false; showNotice("此系统的页面静音接口不可用。") }
    }
    private func installScript(on controller: WKUserContentController) {
        guard let url = BrowserAssets.url("Runtime", "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            showNotice("缺少运行脚本，后台页面适配不可用。"); return
        }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source.replacingOccurrences(of: "__CONFIG__", with: policyJSON), injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        let script = "window.__pagekeepConfigure && window.__pagekeepConfigure(\(policyJSON)); true;"
        view.evaluateJavaScript(script, completionHandler: nil)
        for (key, frame) in frameInfos where !frame.isMainFrame {
            view.evaluateJavaScript(script, in: frame, in: .page) { [weak self] result in
                if case .failure = result { self?.frameInfos.removeValue(forKey: key) }
            }
        }
        changed?()
    }
    func setMode(_ mode: RunMode) { record.mode = mode; settingsChanged?(); applyPolicy() }
    func setCompatibility(_ value: Bool) { record.compatibility = value; settingsChanged?(); applyPolicy() }
    func setForceFrames(_ value: Bool) { record.forceFrames = value; settingsChanged?(); applyPolicy() }
    func setAutoFocus(_ value: Bool) {
        record.autoFocus = value; settingsChanged?(); applyPolicy()
        if !value { focus("off") }
    }
    func setProbe(_ value: Bool) { probeEnabled = value; if value { samples.removeAll() }; applyPolicy() }
    func focus(_ action: String) {
        guard ["on", "off", "pick"].contains(action) else { return }
        if action == "off" { record.autoFocus = false; settingsChanged?(); applyPolicy() }
        webView?.evaluateJavaScript("window.__pagekeepFocus && window.__pagekeepFocus('\(action)'); true;", completionHandler: nil)
    }
    func toggleMute() {
        guard let view = webView else { return }
        if PKMute(view, !record.muted) { record.muted.toggle(); changed?() }
        else { showNotice("此系统的页面静音接口不可用。") }
    }
    func inspect(_ action: String = "show") {
        guard let view = webView else { return }
        if !PKInspector(view, action) { showNotice("内置检查器不可用。可在 Safari 的“开发”菜单中选择 Pagekeep 的页面。") }
    }
    func navigate(_ url: URL) {
        record.sleeping = false; crashed = false
        if Address.pageKey(URL(string: record.url)) != Address.pageKey(url) {
            let rule = ruleForURL?(url)
            record.mode = rule?.mode ?? (Address.isDMM(url) ? .continuous : .eco)
            record.autoFocus = rule?.autoFocus ?? Address.isDMM(url)
            record.compatibility = rule?.compatibility ?? false
            record.forceFrames = rule?.forceFrames ?? false
        }
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
    func sleep() {
        guard webView != nil else { return }
        record.sleeping = true; dispose(); changed?()
    }
    func dispose() {
        probeEnabled = false; frameInfos.removeAll(); observations.removeAll(); samples.removeAll()
        if let view = webView {
            PKInspector(view, "close"); view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "pagekeep")
            view.configuration.userContentController.removeAllUserScripts(); view.removeFromSuperview()
        }
        webView = nil; focused = false; policyApplied = false
    }
    func showNotice(_ message: String) {
        notice = String(message.prefix(500)); let generation = UUID(); noticeGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.noticeGeneration == generation { self?.notice = nil } }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let key = body["frameID"] as? String, key.count < 100 else { return }
        if frameInfos.count < 64 || frameInfos[key] != nil { frameInfos[key] = message.frameInfo }
        switch kind {
        case "ready":
            webView?.evaluateJavaScript("window.__pagekeepConfigure && window.__pagekeepConfigure(\(policyJSON)); true;", in: message.frameInfo, in: .page, completionHandler: nil)
        case "applied":
            if message.frameInfo.isMainFrame { policyApplied = (body["continuous"] as? Bool) == (record.mode == .continuous) }
        case "focus":
            if message.frameInfo.isMainFrame { focused = body["active"] as? Bool ?? false }
        case "notice":
            if message.frameInfo.isMainFrame, let text = body["text"] as? String { showNotice(text) }
        case "probe":
            guard probeEnabled, let elapsed = body["elapsed"] as? Double, elapsed.isFinite,
                  let ticks = body["ticks"] as? Int, let frames = body["frames"] as? Int,
                  let gap = body["gap"] as? Double, gap.isFinite else { return }
            let label = message.frameInfo.isMainFrame ? "主页面" : "子框架 \(key.prefix(6))"
            if samples.count < 64 || samples[label] != nil { samples[label] = (ProbeSample(elapsed: elapsed, ticks: ticks, frames: frames, largestGap: gap), Date(), body["realHidden"] as? Bool ?? false) }
        default: break
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        frameInfos.removeAll(); samples.removeAll(); focused = false; policyApplied = false; crashed = false
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, let rule = ruleForURL?(url) {
            record.mode = rule.mode; record.autoFocus = rule.autoFocus
            record.compatibility = rule.compatibility; record.forceFrames = rule.forceFrames
        } else if !Address.isDMM(webView.url), webView.url?.scheme != "about" {
            record.compatibility = false; record.forceFrames = false; record.autoFocus = false
        }
        applyPolicy()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyPolicy()
        if let url = webView.url, ["https", "http"].contains(url.scheme ?? "") { visited?(webView.title ?? url.host ?? "网页", url.absoluteString) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) { if (error as NSError).code != NSURLErrorCancelled { showNotice(error.localizedDescription) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashed = true; policyApplied = false; showNotice("此页面的网页进程已退出。点击重新加载恢复；其他页面不会主动刷新。"); changed?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if ["https", "http", "about", "blob"].contains(url.scheme?.lowercased() ?? "") {
            if action.targetFrame?.isMainFrame == true, ["http", "https"].contains(url.scheme ?? ""), Address.pageKey(webView.url) != Address.pageKey(url) {
                let rule = ruleForURL?(url)
                record.mode = rule?.mode ?? (Address.isDMM(url) ? .continuous : .eco)
                record.autoFocus = rule?.autoFocus ?? Address.isDMM(url)
                record.compatibility = rule?.compatibility ?? false; record.forceFrames = rule?.forceFrames ?? false
                applyPolicy()
            }
            decisionHandler(action.shouldPerformDownload ? .download : .allow); return
        }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
              !["javascript", "data", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        confirm(title: "在外部应用中打开？", message: "此页面希望打开 \(url.scheme ?? "外部") 链接。", accept: "打开") { accepted in if accepted { NSWorkspace.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { DownloadCenter.shared.add(download, window: webView.window) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { DownloadCenter.shared.add(download, window: webView.window) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { openWindow?(configuration, action) }
    func webViewDidClose(_ webView: WKWebView) { closeRequested?() }
    private func origin(_ frame: WKFrameInfo) -> String { "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)" }
    private func show(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView?.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
    func confirm(title: String, message: String, accept: String = "确定", completion: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: accept); alert.addButton(withTitle: "取消")
        show(alert) { completion($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = origin(frame); alert.informativeText = String(message.prefix(4000)); alert.addButton(withTitle: "好")
        show(alert) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        confirm(title: origin(frame), message: String(message.prefix(4000)), completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = origin(frame); alert.informativeText = String(prompt.prefix(4000))
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        show(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        if let window = webView.window { panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) } }
        else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let device = type == .camera ? "摄像头" : (type == .microphone ? "麦克风" : "摄像头与麦克风")
        let key = Address.originKey(webView.url) + "|\(origin.protocol)://\(origin.host):\(origin.port)|\(type.rawValue)"
        if let saved = SitePermissions.shared.decision(for: key) { decisionHandler(saved ? .grant : .deny); return }
        let alert = NSAlert(); alert.messageText = "允许使用\(device)？"
        alert.informativeText = "请求网站：\(origin.protocol)://\(origin.host)\n当前页面：\(webView.url?.host ?? "未知")"
        alert.addButton(withTitle: "允许"); alert.addButton(withTitle: "不允许")
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "记住此网站的选择"
        show(alert) { answer in
            let granted = answer == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on { SitePermissions.shared.save(key: key, label: "\(origin.host) · \(device)", granted: granted) }
            decisionHandler(granted ? .grant : .deny)
        }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard challenge.previousFailureCount < 3 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let alert = NSAlert(); alert.messageText = "网站要求登录"; alert.informativeText = challenge.protectionSpace.host
        let user = NSTextField(string: challenge.proposedCredential?.user ?? ""); user.placeholderString = "用户名"
        let password = NSSecureTextField(string: ""); password.placeholderString = "密码"
        let stack = NSStackView(views: [user, password]); stack.orientation = .vertical; stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        user.widthAnchor.constraint(equalToConstant: 300).isActive = true; password.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack; alert.addButton(withTitle: "登录"); alert.addButton(withTitle: "取消")
        show(alert) { answer in
            if answer == .alertFirstButtonReturn { completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
