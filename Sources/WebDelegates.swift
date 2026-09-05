import Cocoa
import WebKit

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http","https","about","blob","data"].contains(scheme) || (scheme == "file" && self.url?.isFileURL == true) {
            if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), action.targetFrame?.isMainFrame == true {
                owner?.newTab(url:url,select:action.modifierFlags.contains(.shift)); decisionHandler(.cancel); return
            }
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated || ["mailto","tel"].contains(scheme) else { return }
        let alert = NSAlert(); alert.messageText = "在其他应用中打开链接？"
        alert.informativeText = "\(url.absoluteString)\n\n此操作会离开 Still。"
        alert.addButton(withTitle:"打开"); alert.addButton(withTitle:"取消")
        present(alert) { result in if result == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.begin(download,window:owner?.window)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.begin(download,window:owner?.window)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentGeneration += 1; focusRequest += 1; frames.removeAll()
        surface.focus(nil); failure = nil
        surface.placeholder?.removeFromSuperview(); surface.placeholder = nil
        owner?.refreshChrome()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            record.url = url.absoluteString
            let key = Address.gameKey(url)
            if key != lastProfileKey {
                record.preferences = BrowserStore.shared.preferences(for:url)
                lastProfileKey = key; applyPolicy(persist:false)
            }
        }
        changed()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastLoadedAt = Date(); changed()
        BrowserStore.shared.visit(title:record.title,url:url)
        if record.preferences.autoFocus { scheduleFocus() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure(error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure(error.localizedDescription) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        frames.removeAll(); showFailure("页面进程已退出。其他标签页没有重新加载。")
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic,NSURLAuthenticationMethodHTTPDigest,NSURLAuthenticationMethodDefault].contains(method) else {
            completionHandler(.performDefaultHandling,nil); return
        }
        guard challenge.previousFailureCount < 3 else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        let username = NSTextField(string:challenge.proposedCredential?.user ?? "")
        username.placeholderString = "用户名"
        let password = NSSecureTextField(string:""); password.placeholderString = "密码"
        let fields = stack([username,password],spacing:8)
        fields.frame = NSRect(x:0,y:0,width:320,height:62)
        username.widthAnchor.constraint(equalToConstant:320).isActive = true
        password.widthAnchor.constraint(equalToConstant:320).isActive = true
        let alert = NSAlert(); alert.messageText = "网站需要登录"
        alert.informativeText = "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        alert.accessoryView = fields; alert.addButton(withTitle:"登录"); alert.addButton(withTitle:"取消")
        present(alert) { result in
            if result == .alertFirstButtonReturn { completionHandler(.useCredential,URLCredential(user:username.stringValue,password:password.stringValue,persistence:.forSession)) }
            else { completionHandler(.cancelAuthenticationChallenge,nil) }
        }
    }
}

extension BrowserTab: WKUIDelegate {
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        surface.focus(nil)
        if let owner, let window = owner.window {
            owner.selectTab(id)
            if window.attachedSheet == nil { alert.beginSheetModal(for:window,completionHandler:completion) }
            else { completion(alert.runModal()) }
        } else { completion(alert.runModal()) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let owner else { return nil }
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let window = (NSApp.delegate as? AppDelegate)?.newWindow(empty:true)
            return window?.newTab(configuration:configuration,load:false).webView
        }
        return owner.newTab(configuration:configuration,load:false).webView
    }
    func webViewDidClose(_ webView: WKWebView) { owner?.closeTab(id,confirm:false) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(6000)); alert.addButton(withTitle:"好")
        present(alert) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(6000)); alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消")
        present(alert) { result in completionHandler(result == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let input = NSTextField(string:defaultText ?? ""); input.frame = NSRect(x:0,y:0,width:320,height:26)
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = String(prompt.prefix(6000))
        alert.accessoryView = input; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消")
        present(alert) { result in completionHandler(result == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        if let window = owner?.window { panel.beginSheetModal(for:window) { result in completionHandler(result == .OK ? panel.urls : nil) } }
        else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let permission = type == .camera ? "摄像头" : type == .microphone ? "麦克风" : "摄像头和麦克风"
        let alert = NSAlert(); alert.messageText = "允许网站使用\(permission)？"
        alert.informativeText = "请求来源：\(origin.protocol)://\(origin.host)\n当前页面：\(url?.host ?? "未知")"
        alert.addButton(withTitle:"允许这一次"); alert.addButton(withTitle:"不允许")
        present(alert) { result in decisionHandler(result == .alertFirstButtonReturn ? .grant : .deny) }
    }
}
