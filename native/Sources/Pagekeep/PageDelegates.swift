import AppKit
import WebKit
import BrowserCore

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { prepareForNavigation() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, ["http", "https"].contains(url.scheme ?? "") { applyRule(for: url) }
        applyPolicy()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyPolicy()
        if record.autoFocus { NativeFocus.shared.perform("auto", tab: self) }
        let url = webView.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.record.autoFocus, self.webView?.url == url else { return }
            NativeFocus.shared.perform("auto", tab: self)
        }
        if let url, ["https", "http"].contains(url.scheme ?? "") { visited?(webView.title ?? url.host ?? "网页", url.absoluteString) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showNotice(error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showNotice(error.localizedDescription) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashed = true; policyApplied = false; NativeFocus.shared.remove(webView)
        showNotice("此页面的网页进程已退出。点击重新加载恢复；其他页面不会主动刷新。"); changed?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if ["https", "http", "about", "blob"].contains(url.scheme?.lowercased() ?? "") {
            if action.targetFrame?.isMainFrame == true, ["http", "https"].contains(url.scheme ?? ""),
               (Address.pageKey(webView.url) != Address.pageKey(url) || Address.originKey(webView.url) != Address.originKey(url)) {
                applyRule(for: url); applyPolicy()
            }
            decisionHandler(action.shouldPerformDownload ? .download : .allow); return
        }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
              !["javascript", "data", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        confirm(title: "在外部应用中打开？", message: "此页面希望打开 \(url.scheme ?? "外部") 链接。", accept: "打开") { accepted in if accepted { NSWorkspace.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) { decisionHandler(response.canShowMIMEType ? .allow : .download) }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { DownloadCenter.shared.add(download, window: presentationWindow) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { DownloadCenter.shared.add(download, window: presentationWindow) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { openWindow?(configuration, action) }
    func webViewDidClose(_ webView: WKWebView) { closeRequested?() }
    private func origin(_ frame: WKFrameInfo) -> String { "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)" }
    private func show(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = presentationWindow { alert.beginSheetModal(for: window, completionHandler: completion) } else { completion(alert.runModal()) }
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
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { confirm(title: origin(frame), message: String(message.prefix(4000)), completion: completionHandler) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = origin(frame); alert.informativeText = String(prompt.prefix(4000))
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        show(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        if let window = presentationWindow { panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) } } else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
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
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method) else { completionHandler(.performDefaultHandling, nil); return }
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
