import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor
final class BrowserWindow: NSWindowController, NSWindowDelegate {
    let model: BrowserModel
    private var allowClose = false
    init(model: BrowserModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pagekeep"; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 740, height: 500)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: BrowserChrome(model: model))
        super.init(window: window); window.delegate = self
        window.center(); window.setFrameAutosaveName("PagekeepBrowser")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose || !(model.tabs.contains { $0.running && $0.record.mode == .continuous }) { return true }
        let alert = NSAlert(); alert.messageText = "关闭窗口并结束其中的页面？"
        alert.informativeText = "要继续后台运行，请最小化窗口或切换到其他应用。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "结束并关闭")
        alert.beginSheetModal(for: sender) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.allowClose = true; sender.performClose(nil) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        model.tabs.forEach { $0.dispose() }
        AppDelegate.shared?.windows.removeAll { $0 === self }
        AppDelegate.shared?.scheduleSave(); AppPower.shared.update()
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var windows: [BrowserWindow] = []
    var saveWork: DispatchWorkItem?
    private var status: NSStatusItem?
    private var terminating = false
    var activeModel: BrowserModel? { (NSApp.mainWindow?.windowController as? BrowserWindow)?.model ?? windows.last?.model }
    override init() { super.init(); Self.shared = self }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["restoreSession": true, "preventIdleSleep": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        makeMenus()
        if CommandLine.arguments.contains("--smoke-test") { let browser = newWindow(); SmokeTest.run(browser: browser); return }
        if UserDefaults.standard.bool(forKey: "restoreSession"), let session = LibraryStore.shared.restore(), !session.windows.isEmpty {
            for record in session.windows { _ = newWindow(record: record) }
        } else { _ = newWindow() }
        makeStatusMenu(); AppPower.shared.update(); NSApp.activate(ignoringOtherApps: true)
    }
    @discardableResult func newWindow(record: WindowRecord? = nil, tab: BrowserTab? = nil) -> BrowserWindow {
        let model = BrowserModel(record: record)
        if let tab { model.tabs.forEach { $0.dispose() }; model.tabs.removeAll(); model.append(tab) }
        let browser = BrowserWindow(model: model); windows.append(browser)
        browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); AppPower.shared.update(); scheduleSave()
        return browser
    }
    func transfer(_ id: UUID, to destination: BrowserModel, before target: UUID) {
        guard let source = windows.map(\.model).first(where: { $0.tabs.contains { $0.id == id } }),
              let tab = source.tabs.first(where: { $0.id == id }) else { return }
        if source === destination { destination.move(id, before: target); return }
        source.tabs.removeAll { $0.id == id }
        if source.selected == id { source.selected = source.tabs.first?.id }
        if source.tabs.isEmpty { source.newTab() }
        destination.wire(tab)
        let index = destination.tabs.firstIndex { $0.id == target } ?? destination.tabs.count
        destination.tabs.insert(tab, at: index); destination.selected = id; scheduleSave()
    }
    func scheduleSave() {
        guard !CommandLine.arguments.contains("--smoke-test"), !terminating else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    func save() {
        guard !CommandLine.arguments.contains("--smoke-test") else { return }
        LibraryStore.shared.write(SessionRecord(windows: windows.map { $0.model.record }), name: "session.json"); LibraryStore.shared.save()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if windows.flatMap({ $0.model.tabs }).contains(where: { $0.running && $0.record.mode == .continuous }) || DownloadCenter.shared.items.contains(where: { $0.download != nil }) {
            let alert = NSAlert(); alert.messageText = "退出 Pagekeep？"; alert.informativeText = "所有游戏和未完成的下载都会停止。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        saveWork?.cancel(); save(); terminating = true
        windows.flatMap { $0.model.tabs }.forEach { $0.dispose() }; AppPower.shared.update()
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { _ = newWindow() } else { windows.last?.window?.makeKeyAndOrderFront(nil) }; return true
    }
    private func menu(_ name: String, in main: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: ""), submenu = NSMenu(title: name)
        item.submenu = submenu; main.addItem(item); return submenu
    }
    @discardableResult private func item(_ title: String, _ selector: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], in menu: NSMenu, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self; item.keyEquivalentModifierMask = modifiers; menu.addItem(item); return item
    }
    private func makeMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        let app = menu("Pagekeep", in: main)
        item("关于 Pagekeep", #selector(about), in: app); item("设置…", #selector(settings), key: ",", in: app); app.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: ""); services.submenu = NSMenu(title: "服务"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); item("隐藏 Pagekeep", #selector(NSApplication.hide(_:)), key: "h", in: app, target: NSApp)
        item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], in: app, target: NSApp)
        item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), in: app, target: NSApp)
        app.addItem(.separator()); item("退出 Pagekeep", #selector(NSApplication.terminate(_:)), key: "q", in: app, target: NSApp)
        let file = menu("文件", in: main)
        item("新建窗口", #selector(createWindow), key: "n", in: file); item("新建标签页", #selector(createTab), key: "t", in: file)
        item("恢复关闭的标签页", #selector(reopen), key: "t", modifiers: [.command, .shift], in: file)
        item("关闭标签页", #selector(closeTab), key: "w", in: file); item("关闭窗口", #selector(closeWindow), key: "w", modifiers: [.command, .shift], in: file)
        file.addItem(.separator()); item("打开地址…", #selector(focusAddress), key: "l", in: file); item("打印…", #selector(printPage), key: "p", in: file)
        let edit = menu("编辑", in: main)
        for (name, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: name, action: NSSelectorFromString(action), keyEquivalent: key)) }
        edit.addItem(.separator()); item("在页面中查找…", #selector(find), key: "f", in: edit)
        item("查找下一个", #selector(findNext), key: "g", in: edit); item("查找上一个", #selector(findPrevious), key: "g", modifiers: [.command, .shift], in: edit)
        let view = menu("显示", in: main)
        item("重新加载", #selector(reload), key: "r", in: view); item("忽略缓存重新加载", #selector(hardReload), key: "r", modifiers: [.command, .shift], in: view)
        item("停止加载", #selector(stop), key: ".", in: view); view.addItem(.separator())
        item("放大", #selector(zoomIn), key: "+", in: view); item("缩小", #selector(zoomOut), key: "-", in: view); item("实际大小", #selector(resetZoom), key: "0", in: view)
        item("进入/退出全屏", #selector(fullscreen), key: "f", modifiers: [.command, .control], in: view)
        let history = menu("历史记录", in: main)
        item("后退", #selector(back), key: "[", in: history); item("前进", #selector(forward), key: "]", in: history); item("显示历史记录…", #selector(library), key: "y", in: history)
        let bookmarks = menu("书签", in: main); item("添加/移除当前书签", #selector(bookmark), key: "d", in: bookmarks); item("管理书签…", #selector(library), in: bookmarks)
        let game = menu("游戏", in: main)
        item("常速 / 节能", #selector(toggleRun), key: "b", modifiers: [.command, .option], in: game)
        item("静音 / 取消静音", #selector(mute), key: "m", modifiers: [.command, .shift], in: game)
        item("专注 / 完整页面", #selector(focusGame), key: "f", modifiers: [.command, .shift], in: game)
        item("选择游戏区域…", #selector(pickGame), in: game); item("休眠并释放内存…", #selector(sleepTab), in: game)
        game.addItem(.separator()); item("运行设置与检测…", #selector(runtime), in: game); item("打开后台测试页", #selector(testPage), in: game)
        let develop = menu("开发", in: main)
        item("显示 Web Inspector", #selector(inspect), key: "i", modifiers: [.command, .option], in: develop)
        item("显示控制台", #selector(console), key: "j", modifiers: [.command, .option], in: develop)
        item("选择页面元素", #selector(inspectElement), key: "c", modifiers: [.command, .shift], in: develop)
        let window = menu("窗口", in: main); NSApp.windowsMenu = window
        item("最小化", #selector(minimize), key: "m", in: window)
        item("下一个标签页", #selector(nextTab), key: "\t", modifiers: [.control], in: window)
        item("上一个标签页", #selector(previousTab), key: "\t", modifiers: [.control, .shift], in: window)
        for number in 1...9 { let entry = item("选择标签页 \(number)", #selector(numberedTab(_:)), key: String(number), in: window); entry.tag = number }
        window.addItem(.separator()); item("下载…", #selector(downloads), key: "j", modifiers: [.command, .shift], in: window)
    }
    private func makeStatusMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Pagekeep")
        let menu = NSMenu(); item("显示 Pagekeep", #selector(showWindow), in: menu)
        menu.addItem(.separator()); item("所有标签切为节能", #selector(allEco), in: menu); item("所有标签切为常速", #selector(allContinuous), in: menu)
        menu.addItem(.separator()); item("退出 Pagekeep", #selector(NSApplication.terminate(_:)), in: menu, target: NSApp)
        statusItem.menu = menu; status = statusItem
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Pagekeep", .applicationVersion: "0.2.1", .credits: NSAttributedString(string: "系统 WebKit · 后台运行 · 游戏专注\n实际游戏兼容性需要逐项验证。")]) }
    @objc func createWindow() { _ = newWindow() }
    @objc func createTab() { activeModel?.newTab() }
    @objc func reopen() { activeModel?.reopen() }
    @objc func closeTab() { if let model = activeModel, let tab = model.active { model.close(tab) } }
    @objc func closeWindow() { NSApp.mainWindow?.performClose(nil) }
    @objc func focusAddress() { activeModel?.addressFocus += 1 }
    @objc func settings() { activeModel?.panel = .settings }
    @objc func library() { activeModel?.panel = .library }
    @objc func runtime() { activeModel?.panel = .runtime }
    @objc func downloads() { activeModel?.panel = .downloads }
    @objc func find() { activeModel?.findVisible = true }
    @objc func findNext() { activeModel?.find() }
    @objc func findPrevious() { activeModel?.find(backwards: true) }
    @objc func reload() { activeModel?.active?.reload() }
    @objc func hardReload() { activeModel?.active?.reload(bypassCache: true) }
    @objc func stop() { activeModel?.active?.webView?.stopLoading() }
    @objc func back() { activeModel?.active?.webView?.goBack() }
    @objc func forward() { activeModel?.active?.webView?.goForward() }
    @objc func zoomIn() { if let web = activeModel?.active?.webView { web.pageZoom = min(3, web.pageZoom + 0.1) } }
    @objc func zoomOut() { if let web = activeModel?.active?.webView { web.pageZoom = max(0.3, web.pageZoom - 0.1) } }
    @objc func resetZoom() { activeModel?.active?.webView?.pageZoom = 1 }
    @objc func fullscreen() { NSApp.mainWindow?.toggleFullScreen(nil) }
    @objc func minimize() { NSApp.mainWindow?.miniaturize(nil) }
    @objc func nextTab() { activeModel?.relativeTab(1) }
    @objc func previousTab() { activeModel?.relativeTab(-1) }
    @objc func numberedTab(_ sender: NSMenuItem) {
        guard let model = activeModel, !model.tabs.isEmpty else { return }
        let index = sender.tag == 9 ? model.tabs.count - 1 : sender.tag - 1
        if model.tabs.indices.contains(index) { model.select(model.tabs[index]) }
    }
    @objc func bookmark() { if let tab = activeModel?.active { LibraryStore.shared.bookmark(tab) } }
    @objc func toggleRun() { if let tab = activeModel?.active { tab.setMode(tab.record.mode == .continuous ? .eco : .continuous) } }
    @objc func mute() { activeModel?.active?.toggleMute() }
    @objc func focusGame() { if let tab = activeModel?.active { tab.focus(tab.focused ? "off" : "on") } }
    @objc func pickGame() { activeModel?.active?.focus("pick") }
    @objc func sleepTab() { activeModel?.sleepActive() }
    @objc func inspect() { activeModel?.active?.inspect() }
    @objc func console() { activeModel?.active?.inspect("showConsole") }
    @objc func inspectElement() { activeModel?.active?.inspect("toggleElementSelection") }
    @objc func printPage() { activeModel?.active?.webView?.printOperation(with: .shared).run() }
    @objc func testPage() { activeModel?.newTab().loadTestPage() }
    @objc func showWindow() { if windows.isEmpty { _ = newWindow() }; windows.last?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func allEco() { windows.flatMap { $0.model.tabs }.forEach { $0.setMode(.eco) } }
    @objc func allContinuous() { windows.flatMap { $0.model.tabs }.forEach { $0.setMode(.continuous) } }
}
@MainActor enum BrowserAssets {
    static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
}
@main struct PagekeepMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
