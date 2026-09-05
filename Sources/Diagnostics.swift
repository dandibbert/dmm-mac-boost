import Cocoa
import WebKit

@MainActor final class DiagnosticPanel: NSWindowController, NSWindowDelegate {
    static let shared = DiagnosticPanel()
    weak var tab: BrowserTab?
    let text = NSTextView()
    let status = NSTextField(labelWithString:"尚未开始采样")
    var sampling: Timer?
    var report: [String:Any] = [:]
    var sequence = 0
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window); window.title = "运行诊断"; window.minSize = NSSize(width:580,height:400); window.center(); window.delegate = self
        let root = LibraryRoot(frame:window.contentView!.bounds); window.contentView = root
        let explanation = caption("这里测量原生动画帧和定时器，不代表实际游戏进度已通过验证。分别检查切换标签、遮挡、最小化和其他桌面。诊断仅在开始采样后运行。",size:12,secondary:true)
        root.addSubview(explanation); root.addSubview(status)
        let start = NSButton(title:"开始 / 重置",target:self,action:#selector(start)); start.bezelStyle = .rounded
        let stop = NSButton(title:"停止采样",target:self,action:#selector(stop)); stop.bezelStyle = .rounded
        let copy = NSButton(title:"复制报告",target:self,action:#selector(copyReport)); copy.bezelStyle = .rounded
        [start,stop,copy].forEach { root.addSubview($0) }
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:12,height:12)
        root.addSubview(scroll)
        root.onLayout = { size in
            explanation.frame = NSRect(x:18,y:16,width:size.width-36,height:48)
            start.frame = NSRect(x:16,y:70,width:110,height:28); stop.frame = NSRect(x:134,y:70,width:100,height:28)
            copy.frame = NSRect(x:size.width-120,y:70,width:104,height:28)
            self.status.frame = NSRect(x:18,y:110,width:size.width-36,height:22)
            scroll.frame = NSRect(x:16,y:142,width:size.width-32,height:max(100,size.height-158))
            self.text.setFrameSize(NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,self.text.frame.height)))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ tab: BrowserTab) {
        stop(); self.tab = tab
        status.stringValue = "尚未开始采样 · "+tab.record.title
        report = ["page":Address.redacted(tab.url),"system":ProcessInfo.processInfo.operatingSystemVersionString,"nativeCapabilities":tab.capabilities.mapValues(\.boolValue),"gameProgressVerified":false]
        render(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    @objc func start() {
        guard let tab, let view = tab.webView else { status.stringValue = "页面已经关闭"; return }
        stop(); tab.diagnosing = true; tab.applyPolicy(persist:false)
        view.evaluateJavaScript("globalThis.__stillRuntime?.resetDiagnostics();",completionHandler:nil)
        for frame in tab.frames.values where !frame.isMainFrame {
            view.evaluateJavaScript("globalThis.__stillRuntime?.resetDiagnostics();",in:frame,in:.page,completionHandler:{ _ in })
        }
        status.stringValue = "采样中 · 关闭此窗口会停止采样"
        sampling = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.sample() }
        sample()
    }
    @objc func stop() {
        sequence += 1; sampling?.invalidate(); sampling = nil
        if let tab { tab.diagnosing = false; tab.applyPolicy(persist:false) }
        status.stringValue = "采样已停止"
    }
    func sample() {
        guard let tab, !tab.isClosed, let view = tab.webView else { stop(); return }
        sequence += 1; let ticket = sequence
        report["mode"] = tab.record.preferences.mode.rawValue
        report["inspectorOpen"] = STIsInspected(view)
        report["windowMiniaturized"] = tab.owner?.window?.isMiniaturized ?? false
        report["page"] = Address.redacted(tab.url)
        let frameList = Array(tab.frames.values.prefix(32))
        if frameList.isEmpty {
            view.evaluateJavaScript("globalThis.__stillRuntime?.status();") { [weak self] value,_ in
                guard let self, self.sequence == ticket else { return }
                self.report["frames"] = value.map { [$0] } ?? []; self.render()
            }
        } else {
            var results: [[String:Any]] = []; var remaining = frameList.count
            for frame in frameList {
                view.evaluateJavaScript("globalThis.__stillRuntime?.status();",in:frame,in:.page) { [weak self] result in
                    guard let self, self.sequence == ticket else { return }
                    if case .success(let value) = result, var item = value as? [String:Any] {
                        item["mainFrame"] = frame.isMainFrame
                        item["origin"] = "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)"
                        results.append(item)
                    }
                    remaining -= 1
                    if remaining == 0 { self.report["frames"] = results; self.render() }
                }
            }
        }
    }
    func render() {
        guard JSONSerialization.isValidJSONObject(report), let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]), let string = String(data:data,encoding:.utf8) else { return }
        text.string = string
    }
    @objc func copyReport() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.string,forType:.string) }
    func windowWillClose(_ notification: Notification) { stop() }
}
