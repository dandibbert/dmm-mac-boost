import Cocoa
import WebKit

@MainActor final class DownloadEntry {
    let id = UUID()
    var download: WKDownload?
    weak var source: WKWebView?
    var request: URLRequest?
    var destination: URL?
    var title = "准备下载"
    var state = "等待保存位置"
    var finished = false
    var paused = false
    var resumeData: Data?
    var observation: NSKeyValueObservation?
    var received: Int64 = 0
    var total: Int64 = 0
}
@MainActor final class DownloadManager: NSWindowController, WKDownloadDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = DownloadManager()
    var entries: [DownloadEntry] = []
    var parents: [ObjectIdentifier: NSWindow] = [:]
    let table = NSTableView()
    let empty = NSTextField(labelWithString:"下载的文件会显示在这里")
    var lastRefresh = Date.distantPast
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:690,height:420),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window); window.title = "下载"; window.minSize = NSSize(width:560,height:300); window.center()
        let root = LibraryRoot(frame:window.contentView!.bounds); window.contentView = root
        for (id,title,width) in [("name","文件",300.0),("progress","进度",180.0),("status","状态",160.0)] {
            let column = NSTableColumn(identifier:.init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.style = .inset
        table.target = self; table.doubleAction = #selector(reveal)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        root.addSubview(scroll); empty.textColor = .secondaryLabelColor; root.addSubview(empty)
        let revealButton = NSButton(title:"在 Finder 中显示",target:self,action:#selector(reveal)); revealButton.bezelStyle = .rounded
        let pauseButton = NSButton(title:"暂停",target:self,action:#selector(pause)); pauseButton.bezelStyle = .rounded
        let resumeButton = NSButton(title:"继续 / 重试",target:self,action:#selector(resume)); resumeButton.bezelStyle = .rounded
        let clearButton = NSButton(title:"清除已结束记录",target:self,action:#selector(clearCompleted)); clearButton.bezelStyle = .rounded
        for button in [revealButton,pauseButton,resumeButton,clearButton] { root.addSubview(button) }
        root.onLayout = { size in
            scroll.frame = NSRect(x:12,y:12,width:size.width-24,height:size.height-64)
            self.empty.frame = NSRect(x:24,y:70,width:size.width-48,height:24)
            revealButton.frame = NSRect(x:12,y:size.height-40,width:132,height:28)
            pauseButton.frame = NSRect(x:152,y:size.height-40,width:60,height:28)
            resumeButton.frame = NSRect(x:220,y:size.height-40,width:100,height:28)
            clearButton.frame = NSRect(x:size.width-160,y:size.height-40,width:148,height:28)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    var activeCount: Int { entries.filter { !$0.finished && !$0.paused && $0.download != nil }.count }
    func show() { refresh(force:true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func begin(_ download: WKDownload, window: NSWindow?) {
        let entry = DownloadEntry(); entry.source = download.webView; entry.request = download.originalRequest
        entries.insert(entry,at:0); attach(download,to:entry)
        if let window { parents[ObjectIdentifier(download)] = window }
    }
    func attach(_ download: WKDownload,to entry: DownloadEntry) {
        entry.download = download; entry.finished = false; entry.paused = false; entry.state = "下载中"
        download.delegate = self
        entry.observation = download.progress.observe(\.fractionCompleted,options:[.initial,.new]) { [weak self,weak entry] progress,_ in
            DispatchQueue.main.async {
                entry?.received = progress.completedUnitCount; entry?.total = progress.totalUnitCount
                self?.refresh()
            }
        }
        refresh(force:true)
    }
    func entry(for download: WKDownload) -> DownloadEntry? { entries.first { $0.download === download } }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let entry = entry(for:download) else { completionHandler(nil); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
        panel.directoryURL = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
        entry.title = panel.nameFieldStringValue
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            if result == .OK, let url = panel.url { entry.destination = url; entry.state = "下载中"; completionHandler(url) }
            else { entry.paused = true; entry.state = "已取消"; completionHandler(nil) }
            self?.parents.removeValue(forKey:ObjectIdentifier(download)); self?.refresh(force:true)
        }
        if let parent = parents[ObjectIdentifier(download)], parent.attachedSheet == nil { panel.beginSheetModal(for:parent,completionHandler:finish) }
        else { finish(panel.runModal()) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = entry(for:download) else { return }
        entry.state = "已完成"; entry.finished = true; entry.observation = nil
        download.delegate = nil; entry.download = nil; entry.resumeData = nil; refresh(force:true)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = entry(for:download) else { return }
        entry.resumeData = resumeData; entry.observation = nil; entry.download = nil
        if !entry.paused { entry.state = error.localizedDescription; entry.paused = true }
        refresh(force:true)
    }
    func refresh(force: Bool = false) {
        guard isWindowLoaded, force || Date().timeIntervalSince(lastRefresh)>0.3 else { return }
        guard force || window?.isVisible == true else { return }
        lastRefresh = Date(); empty.isHidden = !entries.isEmpty; table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let entry = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return entry.title
        case "progress":
            let received = ByteCountFormatter.string(fromByteCount:entry.received,countStyle:.file)
            return entry.total>0 ? received+" / "+ByteCountFormatter.string(fromByteCount:entry.total,countStyle:.file) : received
        default: return entry.state
        }
    }
    var selected: DownloadEntry? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    @objc func reveal() { if let url = selected?.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc func pause() {
        guard let entry = selected, let download = entry.download else { return }
        entry.paused = true; entry.state = "已暂停"
        download.cancel { [weak self] data in entry.resumeData = data; entry.download = nil; entry.observation = nil; self?.refresh(force:true) }
    }
    @objc func resume() {
        guard let entry = selected, entry.paused, let view = entry.source ?? (NSApp.delegate as? AppDelegate)?.activeWindow?.current?.webView else { return }
        entry.paused = false; entry.state = "正在恢复"
        if let data = entry.resumeData { view.resumeDownload(fromResumeData:data) { [weak self] download in self?.attach(download,to:entry) } }
        else if let request = entry.request { view.startDownload(using:request) { [weak self] download in self?.attach(download,to:entry) } }
        refresh(force:true)
    }
    @objc func clearCompleted() { entries.removeAll { $0.finished || ($0.paused && $0.resumeData == nil) }; refresh(force:true) }
}
