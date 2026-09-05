import Cocoa
import WebKit

@main struct StillMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of:"--self-test"), arguments.indices.contains(index+1) {
            RuntimeEnvironment.testing = true
            BrowserStore.shared = BrowserStore(directory:URL(fileURLWithPath:arguments[index+1],isDirectory:true).appendingPathComponent("isolated-state"))
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate; application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [BrowserWindow] = []
    weak var activeWindow: BrowserWindow?
    var quitting = false
    var activity: NSObjectProtocol?
    var sleepActivity: NSObjectProtocol?
    var didRestore = false
    var selfTest: SelfTest?
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        if RuntimeEnvironment.testing, let index = CommandLine.arguments.firstIndex(of:"--self-test"), CommandLine.arguments.indices.contains(index+1) {
            selfTest = SelfTest(app:self,output:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true))
            selfTest?.start(); return
        }
        if BrowserStore.shared.state.settings.restoreSession {
            for record in BrowserStore.shared.state.windows { _ = newWindow(record:record) }
        }
        if windows.isEmpty { _ = newWindow() }
        didRestore = true
        NSApp.activate(ignoringOtherApps:true)
        if let error = BrowserStore.shared.loadError {
            activeWindow?.notice("未能读取设置文件",detail:error+"\n\n原文件未被覆盖。可在设置中保留备份后重新启用保存。")
        }
    }
    @discardableResult func newWindow(record: WindowRecord? = nil,empty: Bool = false) -> BrowserWindow {
        let controller = BrowserWindow(record:record,empty:empty)
        windows.append(controller); activeWindow = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        sessionsChanged(); return controller
    }
    func windowClosed(_ window: BrowserWindow) {
        windows.removeAll { $0 === window }
        if activeWindow === window { activeWindow = windows.last }
        sessionsChanged()
    }
    func sessionsChanged() {
        let steadyCount = windows.reduce(0) { $0+$1.tabs.filter(\.isSteady).count }
        if steadyCount > 0 && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Keep explicitly selected game sessions running")
        } else if steadyCount == 0, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
        let preventSleep = steadyCount > 0 && BrowserStore.shared.state.settings.preventIdleSleep
        if preventSleep && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options:.idleSystemSleepDisabled,reason:"User requested idle-sleep prevention while games run")
        } else if !preventSleep, let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil
        }
        for controller in windows {
            guard let window = controller.window as? BrowserNativeWindow else { continue }
            let count = controller.tabs.filter(\.isSteady).count
            if window.steadySessions != count {
                window.steadySessions = count
                NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:window)
            }
        }
        if didRestore && !quitting && !RuntimeEnvironment.testing {
            BrowserStore.shared.state.windows = windows.map(\.snapshot); BrowserStore.shared.scheduleSave()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { _ = newWindow() }
        else if !flag { windows.first?.window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func application(_ application: NSApplication,open urls: [URL]) {
        let controller = activeWindow ?? newWindow(empty:true)
        for url in urls {
            let tab = controller.newTab(load:false)
            tab.navigate(to:url)
        }
        application.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = windows.reduce(0) { $0+$1.tabs.filter(\.isSteady).count }
        let downloads = DownloadManager.shared.activeCount
        if !RuntimeEnvironment.testing && BrowserStore.shared.state.settings.confirmQuit && (count > 0 || downloads > 0) {
            let alert = NSAlert(); alert.messageText = "退出 Still？"
            alert.informativeText = "\(count) 个常速标签和 \(downloads) 个下载会停止。再次启动时只能恢复页面地址，不能恢复仍在内存中的游戏状态。"
            alert.addButton(withTitle:"退出"); alert.addButton(withTitle:"取消")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true
        if !RuntimeEnvironment.testing {
            BrowserStore.shared.state.windows = windows.map(\.snapshot); BrowserStore.shared.flush()
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
    }
    func withWindow(_ action: (BrowserWindow) -> Void) { action(activeWindow ?? newWindow()) }
    func installMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title:title,action:nil,keyEquivalent:"")
            let menu = NSMenu(title:title); menu.autoenablesItems = false; item.submenu = menu; bar.addItem(item); return menu
        }
        let app = section("Still")
        app.command("关于 Still") { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Still",.applicationVersion:"0.1.0",.version:"Native WebKit Browser"]) }
        app.command("设置…",key:",") { SettingsPanel.shared.show() }
        app.addItem(.separator())
        let servicesItem = NSMenuItem(title:"服务",action:nil,keyEquivalent:"")
        let services = NSMenu(title:"服务"); servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        app.command("隐藏 Still",key:"h") { NSApp.hide(nil) }
        app.command("隐藏其他应用",key:"h",modifiers:[.command,.option]) { NSApp.hideOtherApplications(nil) }
        app.command("显示全部") { NSApp.unhideAllApplications(nil) }
        app.addItem(.separator()); app.command("退出 Still",key:"q") { NSApp.terminate(nil) }

        let file = section("文件")
        file.command("新建窗口",key:"n") { [weak self] in self?.newWindow() }
        file.command("新建标签页",key:"t") { [weak self] in self?.withWindow { $0.newTab(); $0.focusAddress() } }
        file.command("打开文件…",key:"o") { [weak self] in
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { self?.application(NSApp,open:panel.urls) }
        }
        file.command("关闭标签页",key:"w") { [weak self] in guard let window = self?.activeWindow, let tab = window.current else { return }; window.closeTab(tab.id) }
        file.command("关闭窗口",key:"w",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.window?.performClose(nil) }
        file.command("恢复关闭的标签",key:"t",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.restoreClosedTab() }
        file.addItem(.separator())
        file.command("保存网页…",key:"s") { [weak self] in self?.activeWindow?.savePage() }
        file.command("保存页面截图…") { [weak self] in self?.activeWindow?.saveScreenshot() }
        file.command("打印…",key:"p") { [weak self] in self?.activeWindow?.printPage() }

        let edit = section("编辑"); edit.autoenablesItems = true
        for (title,selector,key,mods) in [
            ("撤销","undo:","z",NSEvent.ModifierFlags.command),
            ("重做","redo:","z",[.command,.shift]),
            ("剪切","cut:","x",.command),("复制","copy:","c",.command),
            ("粘贴","paste:","v",.command),("粘贴并匹配样式","pasteAsPlainText:","v",[.command,.option,.shift]),
            ("全选","selectAll:","a",.command)
        ] {
            let item = NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key)
            item.keyEquivalentModifierMask = mods; edit.addItem(item)
        }
        edit.addItem(.separator()); edit.command("在页面中查找…",key:"f") { [weak self] in self?.activeWindow?.showFind() }
        edit.command("查找下一个",key:"g") { [weak self] in self?.activeWindow?.find() }
        edit.command("查找上一个",key:"g",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.find(backwards:true) }

        let view = section("显示")
        view.command("聚焦地址栏",key:"l") { [weak self] in self?.withWindow { $0.focusAddress() } }
        view.command("后退",key:"[") { [weak self] in self?.activeWindow?.current?.webView?.goBack() }
        view.command("前进",key:"]") { [weak self] in self?.activeWindow?.current?.webView?.goForward() }
        view.command("刷新",key:"r") { [weak self] in self?.activeWindow?.reloadOrStop() }
        view.command("忽略缓存重新加载",key:"r",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.hardReload() }
        view.command("停止加载",key:".") { [weak self] in self?.activeWindow?.current?.webView?.stopLoading() }
        view.addItem(.separator())
        view.command("书签与历史记录",key:"s",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.toggleSidebar() }
        view.command("收藏当前页面",key:"d") { [weak self] in self?.activeWindow?.bookmark() }
        view.command("下载",key:"j",modifiers:[.command,.option]) { DownloadManager.shared.show() }
        view.addItem(.separator())
        view.command("放大",key:"+") { [weak self] in self?.activeWindow?.zoom(0.1) }
        view.command("缩小",key:"-") { [weak self] in self?.activeWindow?.zoom(-0.1) }
        view.command("实际大小",key:"0") { [weak self] in self?.activeWindow?.zoom(0,reset:true) }
        view.command("切换游戏专注",key:"f",modifiers:[.command,.option]) { [weak self] in self?.activeWindow?.current?.toggleFocus() }
        view.command("进入 / 退出全屏",key:"f",modifiers:[.command,.control]) { [weak self] in self?.activeWindow?.window?.toggleFullScreen(nil) }

        let tabs = section("标签页")
        tabs.command("下一个标签页",key:"\t",modifiers:.control) { [weak self] in self?.activeWindow?.nextTab(1) }
        tabs.command("上一个标签页",key:"\t",modifiers:[.control,.shift]) { [weak self] in self?.activeWindow?.nextTab(-1) }
        tabs.command("将标签页移到新窗口") { [weak self] in guard let w = self?.activeWindow, let id = w.current?.id else { return }; w.detach(id) }
        for index in 1...9 {
            tabs.command("选择标签 \(index)",key:String(index)) { [weak self] in
                guard let w = self?.activeWindow, !w.tabs.isEmpty else { return }
                if index == 9 { w.selectTab(w.tabs.last?.id) }
                else if w.tabs.indices.contains(index-1) { w.selectTab(w.tabs[index-1].id) }
            }
        }
        let run = section("运行")
        run.command("当前标签常速运行") { [weak self] in self?.activeWindow?.current?.setMode(.steady) }
        run.command("当前标签节能") { [weak self] in self?.activeWindow?.current?.setMode(.economy) }
        run.command("当前标签静音 / 取消静音",key:"m",modifiers:[.command,.shift]) { [weak self] in guard let t = self?.activeWindow?.current else { return }; t.setMuted(!t.record.preferences.mute) }
        run.command("全部标签静音") { [weak self] in self?.windows.forEach { $0.tabs.forEach { $0.setMuted(true) } } }
        run.command("全部标签切为节能") { [weak self] in self?.windows.forEach { $0.tabs.forEach { $0.setMode(.economy) } } }
        run.command("休眠当前标签…") { [weak self] in guard let w = self?.activeWindow, let t = w.current else { return }; w.confirmSleep(t) }
        let develop = section("开发")
        develop.command("显示 Web Inspector",key:"i",modifiers:[.command,.option]) { [weak self] in self?.activeWindow?.current?.inspect() }
        develop.command("显示控制台",key:"c",modifiers:[.command,.option]) { [weak self] in self?.activeWindow?.current?.inspect("showConsole") }
        develop.command("显示源代码",key:"u",modifiers:[.command,.option]) { [weak self] in self?.activeWindow?.current?.inspect("showResources") }
        develop.command("检查元素",key:"c",modifiers:[.command,.shift]) { [weak self] in self?.activeWindow?.current?.inspect("toggleElementSelection") }
        develop.command("运行诊断…") { [weak self] in if let tab = self?.activeWindow?.current { DiagnosticPanel.shared.show(tab) } }
        develop.command("打开本地运行测试页") { [weak self] in
            guard let url = Bundle.main.url(forResource:"Fixture",withExtension:"html") else { return }
            self?.withWindow { window in let tab = window.newTab(load:false); tab.navigate(to:url); tab.setMode(.steady) }
        }
        let window = section("窗口"); NSApp.windowsMenu = window
        window.command("最小化",key:"m") { [weak self] in self?.activeWindow?.window?.miniaturize(nil) }
        window.command("缩放") { [weak self] in self?.activeWindow?.window?.zoom(nil) }
        window.command("前置全部窗口") { NSApp.arrangeInFront(nil) }
    }
}
