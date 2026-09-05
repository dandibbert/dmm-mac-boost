import AppKit
import SwiftUI
import WebKit
import BrowserCore

struct BrowserSheet: View {
    let panel: BrowserPanel
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button("完成") { model.panel = nil }.keyboardShortcut(.cancelAction) }.padding(18)
            Divider()
            Group {
                switch panel {
                case .library: LibraryPanel(model: model)
                case .downloads: DownloadsPanel()
                case .runtime: if let tab = model.active { RuntimePanel(tab: tab) }
                case .settings: SettingsPanel(model: model)
                case .siteData: SiteDataPanel()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 620, height: 470)
    }
    var title: String {
        switch panel { case .library: return "书签与历史记录"; case .downloads: return "下载"; case .runtime: return "运行设置与检测"; case .settings: return "设置"; case .siteData: return "网站数据" }
    }
}
struct LibraryPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var library = LibraryStore.shared
    @State private var section = 0
    @State private var query = ""
    var items: [Visit] { (section == 0 ? library.bookmarks : library.history).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("内容", selection: $section) { Text("书签").tag(0); Text("历史记录").tag(1) }.pickerStyle(.segmented).frame(width: 180)
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder)
            }.padding(.horizontal, 18).padding(.top, 14)
            if items.isEmpty { Text("暂无记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(items) { visit in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(visit.title).lineLimit(1); Text(visit.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(); Button("打开") { model.newTab(URL(string: visit.url)); model.panel = nil }
                        Button { if section == 0 { library.bookmarks.removeAll { $0.id == visit.id } } else { library.history.removeAll { $0.id == visit.id } }; library.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }
    }
}
struct RuntimePanel: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("运行模式", selection: Binding(get: { tab.record.mode }, set: { tab.setMode($0) })) { Text("常速").tag(RunMode.continuous); Text("节能").tag(RunMode.eco) }.pickerStyle(.segmented).frame(width: 230)
                Text(tab.record.mode == .continuous ? "保持应用活动并关闭可控制的 WebKit 后台限制。不重新加载当前页面。" : "允许 WebKit 正常节流或挂起后台页面，不主动卸载页面。").font(.callout).foregroundStyle(.secondary)
                Toggle("自动专注游戏区域", isOn: Binding(get: { tab.record.autoFocus }, set: { tab.setAutoFocus($0) }))
                Text("原生裁切保留原页面与游戏框架。识别失败时可在工具栏菜单中手动选择区域。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("后台运行边界").font(.headline)
                Text("此版本不伪装网页可见性，也不替换游戏动画循环。主动在失焦时暂停的游戏，或仍被 WebKit 限制的动画帧，可能无法后台常速。请用实际游戏验证，而不只看开关状态。").font(.callout).foregroundStyle(.secondary)
                if !tab.unavailable.isEmpty { Text("当前系统未提供：" + tab.unavailable.joined(separator: "、")).font(.caption).foregroundStyle(.orange) }
                Text(tab.policyApplied ? "页面检测连接正常 · 实际游戏常速尚未验证" : "等待页面检测连接").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack { Text("调度探针").font(.headline); Spacer(); Toggle("检测", isOn: Binding(get: { tab.probeEnabled }, set: { tab.setProbe($0) })).toggleStyle(.switch).fixedSize() }
                Text("按需测量原生计时器与动画回调。探针不修改网页 API，不代表游戏进度，关闭后停止采样。").font(.caption).foregroundStyle(.secondary)
                if tab.probeEnabled {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 8) {
                            if tab.samples.isEmpty { Text("等待探针结果…").foregroundStyle(.secondary) }
                            ForEach(tab.samples.keys.sorted(), id: \.self) { key in
                                if let (sample, received, _) = tab.samples[key] {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(key).font(.system(size: 12, weight: .medium))
                                        Text(String(format: "计时器 %.1f / 10 Hz · 动画回调 %.1f Hz · 最长间隔 %.2f 秒", sample.ticksPerSecond, sample.framesPerSecond, sample.largestGap)).font(.caption).monospacedDigit()
                                        if context.date.timeIntervalSince(received) > 8 { Text("超过 8 秒未收到回复，可能已挂起。").font(.caption).foregroundStyle(.orange) }
                                        else if sample.stalled { Text("记录到明显停顿。").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                    }
                }
                Button("复制脱敏检测报告") {
                    var lines = ["Pagekeep 0.2.1", "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)", "页面：\(Address.pageKey(URL(string: tab.record.url)))", "模式：\(tab.record.mode.rawValue)", "检测已连接：\(tab.policyApplied)", "缺失能力：\(tab.unavailable.joined(separator: ", "))", "注意：合成探针，不是实际游戏进度。"]
                    for key in tab.samples.keys.sorted() { if let (sample, _, _) = tab.samples[key] { lines.append(String(format: "%@: timer=%.2fHz raf=%.2fHz maxGap=%.2fs elapsed=%.1fs", key, sample.ticksPerSecond, sample.framesPerSecond, sample.largestGap, sample.elapsed)) } }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }.padding(20)
        }
    }
}
struct DownloadsPanel: View {
    @ObservedObject var center = DownloadCenter.shared
    var body: some View {
        if center.items.isEmpty { Text("没有下载项目").foregroundStyle(.secondary) }
        else { List(center.items) { DownloadRow(item: $0) }.listStyle(.inset) }
    }
}
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).lineLimit(1)
                if item.download != nil { ProgressView(value: item.fraction).progressViewStyle(.linear) }
                Text(item.state).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.finished, let url = item.destination { Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            else if item.download != nil { Button("取消") { item.cancel() } }
        }.padding(.vertical, 7)
    }
}
struct SettingsPanel: View {
    @ObservedObject var model: BrowserModel
    @AppStorage("restoreSession") private var restore = true
    @AppStorage("preventIdleSleep") private var preventSleep = false
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var permissions = SitePermissions.shared
    var body: some View {
        Form {
            Section("启动与运行") {
                Toggle("启动时恢复上次标签页", isOn: $restore)
                Toggle("有常速页面时，防止 Mac 因空闲自动睡眠", isOn: $preventSleep).onChange(of: preventSleep) { _ in AppPower.shared.update() }
                Text("不阻止显示器关闭。手动睡眠、合盖睡眠或系统休眠仍会停止游戏。").font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私与权限") {
                Text("登录与缓存仅保存在此 App，不读取 Arc 或 Safari 的登录数据。").font(.callout)
                Button("管理网站数据…") { model.panel = .siteData }
                if permissions.entries.isEmpty { Text("尚未保存摄像头或麦克风权限。").font(.caption).foregroundStyle(.secondary) }
                ForEach(permissions.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) { Text(entry.label); Text(entry.granted ? "允许" : "拒绝").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button("重新询问") { permissions.remove(entry.id) }
                    }
                }
                Text("权限重置在下次请求时生效；正在使用设备的页面可通过关闭标签停止。不会自动上传页面或诊断。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("Pagekeep Native", value: "0.2.1")
                Text("系统 WebKit。静音、内置检查器及部分调度控制使用运行时检测的非公开接口；系统更新后可能失效。").font(.caption).foregroundStyle(.secondary)
                if let problem = library.problem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
}
struct SiteDataPanel: View {
    @State private var records: [WKWebsiteDataRecord] = []
    var body: some View {
        VStack {
            Text("清除网站数据会影响此 App 内该网站的登录与保存内容。").font(.caption).foregroundStyle(.secondary).padding(.top, 14)
            List(records, id: \.displayName) { record in
                HStack {
                    Text(record.displayName); Spacer()
                    Button("清除…") {
                        let alert = NSAlert(); alert.messageText = "清除 \(record.displayName) 的网站数据？"
                        alert.informativeText = "可能退出登录并删除本地游戏数据。正在运行的游戏也可能受影响。"
                        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清除")
                        if alert.runModal() == .alertSecondButtonReturn { WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) { refresh() } }
                    }
                }
            }
        }.onAppear { refresh() }
    }
    private func refresh() { WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { values in records = values.sorted { $0.displayName < $1.displayName } } }
}
