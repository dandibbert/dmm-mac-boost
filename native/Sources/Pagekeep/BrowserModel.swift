import AppKit
import Combine
import SwiftUI
import WebKit
import BrowserCore

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published var bookmarks: [Visit] = []
    @Published var history: [Visit] = []
    var rules: [String: PageRule] = [:]
    @Published var problem: String?
    private struct DataFile: Codable { var bookmarks: [Visit]; var history: [Visit]; var rules: [String: PageRule] }
    let directory: URL
    private var blockedWrites = Set<String>()
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pagekeep Native", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let decoded = try JSONDecoder().decode(DataFile.self, from: Data(contentsOf: url))
                bookmarks = decoded.bookmarks; history = Array(decoded.history.prefix(500)); rules = decoded.rules
            }
        } catch { preserveUnreadable("library.json", reason: "无法读取本地资料：\(error.localizedDescription)") }
    }
    private func preserveUnreadable(_ name: String, reason: String) {
        let original = directory.appendingPathComponent(name)
        let backup = directory.appendingPathComponent(name + ".recovery-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: original, to: backup)
            problem = reason + "；原文件已备份为 " + backup.lastPathComponent + "。"
        } catch {
            blockedWrites.insert(name)
            problem = reason + "；未能备份，已暂停对此文件的写入以保护原数据。"
        }
    }
    func write<T: Encodable>(_ value: T, name: String) {
        guard !blockedWrites.contains(name) else { return }
        do {
            let data = try JSONEncoder().encode(value), url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { problem = "无法保存本地资料：\(error.localizedDescription)" }
    }
    func save() { write(DataFile(bookmarks: bookmarks, history: history, rules: rules), name: "library.json") }
    func recordVisit(title: String, url: String) {
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return }
        history.removeAll { $0.url == url }; history.insert(Visit(title: title, url: url), at: 0)
        history = Array(history.prefix(500))
    }
    func bookmark(_ tab: BrowserTab) {
        guard tab.record.url != "about:blank" else { return }
        if bookmarks.contains(where: { $0.url == tab.record.url }) { bookmarks.removeAll { $0.url == tab.record.url } }
        else { bookmarks.append(Visit(title: tab.title, url: tab.record.url)) }
        save()
    }
    func restore() -> SessionRecord? {
        let url = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let result = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: url))
            guard result.version == 1 else { preserveUnreadable("session.json", reason: "会话来自不兼容的版本"); return nil }
            return result
        } catch { preserveUnreadable("session.json", reason: "上次会话读取失败"); return nil }
    }
}
@MainActor
final class AppPower {
    static let shared = AppPower()
    private var activity: NSObjectProtocol?
    private var sleepActivity: NSObjectProtocol?
    func update() {
        let active = AppDelegate.shared?.windows.flatMap { $0.model.tabs }.contains { $0.running && $0.record.mode == .continuous } ?? false
        if active && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "运行用户选择保持常速的网页") }
        if !active, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
        let preventSleep = active && UserDefaults.standard.bool(forKey: "preventIdleSleep")
        if preventSleep && sleepActivity == nil { sleepActivity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "用户选择在常速运行时防止 Mac 自动睡眠") }
        if !preventSleep, let token = sleepActivity { ProcessInfo.processInfo.endActivity(token); sleepActivity = nil }
    }
}
enum BrowserPanel: String, Identifiable { case library, downloads, runtime, settings, siteData; var id: String { rawValue } }
@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selected: UUID?
    @Published var addressFocus = 0
    @Published var panel: BrowserPanel?
    @Published var findVisible = false
    @Published var findText = ""
    @Published var findResult = ""
    private var recentlyClosed: [TabRecord] = []
    var active: BrowserTab? { tabs.first { $0.id == selected } ?? tabs.first }
    var record: WindowRecord { WindowRecord(tabs: tabs.map(\.record), selected: selected) }
    init(record: WindowRecord? = nil) {
        for item in record?.tabs ?? [] { append(BrowserTab(record: item), select: false) }
        selected = record?.selected
        if tabs.isEmpty { newTab() }
        if !tabs.contains(where: { $0.id == selected }) { selected = tabs.first?.id }
    }
    func wire(_ tab: BrowserTab) {
        tab.changed = { [weak self] in
            guard self != nil else { return }
            AppDelegate.shared?.scheduleSave(); AppPower.shared.update()
        }
        tab.settingsChanged = { [weak tab] in
            guard let tab else { return }
            let key = Address.pageKey(URL(string: tab.record.url))
            if !key.isEmpty { LibraryStore.shared.rules[key] = PageRule(mode: tab.record.mode, autoFocus: tab.record.autoFocus, compatibility: tab.record.compatibility, forceFrames: tab.record.forceFrames) }
            AppDelegate.shared?.scheduleSave()
        }
        tab.visited = { title, url in LibraryStore.shared.recordVisit(title: title, url: url); AppDelegate.shared?.scheduleSave() }
        tab.ruleForURL = { LibraryStore.shared.rules[Address.pageKey($0)] }
        tab.closeRequested = { [weak self, weak tab] in if let tab { self?.close(tab) } }
        tab.openWindow = { [weak self] config, action in
            guard let self else { return nil }
            // WebKit owns this navigation; explicitly loading again breaks window.opener.
            let child = BrowserTab(record: TabRecord(mode: .eco), configuration: config)
            self.append(child); return child.webView
        }
    }
    func append(_ tab: BrowserTab, select: Bool = true) {
        wire(tab); tabs.append(tab)
        if select { selected = tab.id }
        AppDelegate.shared?.scheduleSave(); AppPower.shared.update()
    }
    @discardableResult func newTab(_ url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(record: TabRecord()); append(tab)
        if let url { tab.navigate(url) } else { addressFocus += 1 }
        return tab
    }
    func select(_ tab: BrowserTab) { selected = tab.id; findVisible = false; AppDelegate.shared?.scheduleSave() }
    func navigate(_ text: String) {
        guard let url = Address.resolve(text) else { active?.showNotice("请输入有效的网址。仅支持 HTTP 和 HTTPS；不会执行地址栏中的脚本。"); return }
        active?.navigate(url)
    }
    func close(_ tab: BrowserTab, confirmed: Bool = false) {
        if !confirmed && tab.running && tab.record.mode == .continuous {
            tab.confirm(title: "结束这个游戏页面？", message: "关闭会停止运行。只需暂时离开时，请切换标签或最小化窗口。", accept: "结束并关闭") { [weak self, weak tab] yes in if yes, let tab { self?.close(tab, confirmed: true) } }
            return
        }
        let position = tabs.firstIndex { $0.id == tab.id } ?? 0
        recentlyClosed.insert(tab.record, at: 0); recentlyClosed = Array(recentlyClosed.prefix(20))
        tab.dispose(); tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab() } else if selected == tab.id { selected = tabs[min(position, tabs.count - 1)].id }
        AppDelegate.shared?.scheduleSave(); AppPower.shared.update()
    }
    func reopen() {
        guard var record = recentlyClosed.first else { return }
        recentlyClosed.removeFirst(); record.id = UUID(); record.sleeping = false
        append(BrowserTab(record: record))
    }
    func move(_ id: UUID, before target: UUID) {
        tabs = TabOrder.moving(tabs, id: id, before: target); AppDelegate.shared?.scheduleSave()
    }
    func togglePin(_ tab: BrowserTab) {
        tab.record.pinned.toggle(); tabs = tabs.filter { $0.record.pinned } + tabs.filter { !$0.record.pinned }; AppDelegate.shared?.scheduleSave()
    }
    func relativeTab(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selected } ?? 0
        selected = tabs[(index + offset + tabs.count) % tabs.count].id; AppDelegate.shared?.scheduleSave()
    }
    func sleepActive() {
        guard let tab = active else { return }
        tab.confirm(title: "休眠并释放页面内存？", message: "游戏将停止，返回时需要重新加载。仅切换节能模式不会主动卸载页面。", accept: "休眠") { yes in if yes { tab.sleep() } }
    }
    func find(backwards: Bool = false) {
        guard let web = active?.webView, !findText.isEmpty else { return }
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true
        web.find(findText, configuration: configuration) { [weak self] result in self?.findResult = result.matchFound ? "" : "没有找到" }
    }
    func detach(_ tab: BrowserTab) {
        guard tabs.count > 1 else { return }
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.first?.id }
        AppDelegate.shared?.newWindow(tab: tab); AppDelegate.shared?.scheduleSave()
    }
}
