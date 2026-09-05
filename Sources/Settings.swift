import Cocoa
import WebKit

@MainActor final class SettingsPanel: NSWindowController {
    static let shared = SettingsPanel()
    let restore = NSButton(checkboxWithTitle:"启动时恢复上次的窗口和标签",target:nil,action:nil)
    let preventSleep = NSButton(checkboxWithTitle:"有常速标签时，防止 Mac 自动睡眠",target:nil,action:nil)
    let autoFocus = NSButton(checkboxWithTitle:"打开 DMM 游戏时自动识别游戏区域",target:nil,action:nil)
    let confirmQuit = NSButton(checkboxWithTitle:"退出前确认正在运行的游戏和下载",target:nil,action:nil)
    let search = NSPopUpButton()
    var held: [AnyObject] = []
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:550,height:438),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:window); window.title = "设置"; window.center()
        let root = NSView(); window.contentView = root
        for button in [restore,preventSleep,autoFocus,confirmQuit] { button.target = self; button.action = #selector(changed) }
        search.addItems(withTitles:["Google","Bing","DuckDuckGo"]); search.target = self; search.action = #selector(changed)
        let searchRow = stack([caption("地址栏搜索"),search],orientation:.horizontal,spacing:16)
        let dataButton = NSButton(title:"管理网站数据…",target:self,action:#selector(manageData)); dataButton.bezelStyle = .rounded
        let recover = NSButton(title:"恢复设置文件存储…",target:self,action:#selector(recoverStorage)); recover.bezelStyle = .rounded
        let content = stack([
            caption("浏览",size:14),restore,autoFocus,searchRow,
            separator(),caption("后台运行",size:14),preventSleep,confirmQuit,
            caption("常速与节能不会重新加载页面。整机睡眠时，游戏无法继续运行；此选项不阻止手动睡眠，也不要求显示器保持点亮。",secondary:true),
            separator(),stack([dataButton,recover],orientation:.horizontal),
            caption("所有设置、登录和浏览记录仅保存在本机。没有遥测或自动上传。",secondary:true)
        ],spacing:12)
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-24),content.topAnchor.constraint(equalTo:root.topAnchor,constant:24)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() {
        let settings = BrowserStore.shared.state.settings
        restore.state = settings.restoreSession ? .on : .off
        preventSleep.state = settings.preventIdleSleep ? .on : .off
        autoFocus.state = settings.defaultGameFocus ? .on : .off
        confirmQuit.state = settings.confirmQuit ? .on : .off
        search.selectItem(at:settings.searchEngine.contains("bing") ? 1 : settings.searchEngine.contains("duckduckgo") ? 2 : 0)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    @objc func changed() {
        BrowserStore.shared.state.settings.restoreSession = restore.state == .on
        BrowserStore.shared.state.settings.preventIdleSleep = preventSleep.state == .on
        BrowserStore.shared.state.settings.defaultGameFocus = autoFocus.state == .on
        BrowserStore.shared.state.settings.confirmQuit = confirmQuit.state == .on
        BrowserStore.shared.state.settings.searchEngine = ["https://www.google.com/search","https://www.bing.com/search","https://duckduckgo.com/"][max(0,search.indexOfSelectedItem)]
        BrowserStore.shared.scheduleSave(); (NSApp.delegate as? AppDelegate)?.sessionsChanged()
    }
    @objc func recoverStorage() {
        guard BrowserStore.shared.loadError != nil else {
            let alert = NSAlert(); alert.messageText = "设置存储正常"; alert.runModal(); return
        }
        let alert = NSAlert(); alert.messageText = "保留原文件，并重新启用设置保存？"
        alert.informativeText = "无法读取的原文件会作为备份保留在 Still 的应用数据目录中，不会删除。"
        alert.addButton(withTitle:"保留备份并恢复"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn { BrowserStore.shared.recoverStorage() }
    }
    @objc func manageData() {
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            DispatchQueue.main.async { self?.chooseData(records.sorted { $0.displayName < $1.displayName }) }
        }
    }
    func chooseData(_ records: [WKWebsiteDataRecord]) {
        guard !records.isEmpty else { let alert = NSAlert(); alert.messageText = "没有已保存的网站数据"; alert.runModal(); return }
        let picker = NSPopUpButton(frame:NSRect(x:0,y:0,width:360,height:28))
        picker.addItems(withTitles:records.map(\.displayName))
        let alert = NSAlert(); alert.messageText = "网站数据"
        alert.informativeText = "选择要清除的网站。包括其 Cookie、缓存、IndexedDB 和本地存储。\n清除前会关闭 Still 的全部页面，避免游戏立即重新写入数据。"
        alert.accessoryView = picker; alert.addButton(withTitle:"关闭页面并清除此站点"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn, records.indices.contains(picker.indexOfSelectedItem) else { return }
        let selected = records[picker.indexOfSelectedItem]
        if let app = NSApp.delegate as? AppDelegate {
            for window in app.windows { for tab in window.tabs { tab.close() }; window.tabs.removeAll(); window.window?.close() }
        }
        WKWebsiteDataStore.default().removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),for:[selected]) {
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.newWindow()
                let done = NSAlert(); done.messageText = "已清除 \(selected.displayName) 的网站数据"; done.runModal()
            }
        }
    }
}
