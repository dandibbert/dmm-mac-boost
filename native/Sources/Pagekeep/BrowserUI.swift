import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import BrowserCore

struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    @ObservedObject private var focus = NativeFocus.shared
    func makeNSView(context: Context) -> NativeGameView { let view = NativeGameView(frame: .zero); view.connect(webView); return view }
    func updateNSView(_ view: NativeGameView, context: Context) { view.connect(webView); view.region = focus.regions[ObjectIdentifier(webView)] }
    static func dismantleNSView(_ view: NativeGameView, coordinator: ()) { view.detach() }
}
struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.borderless).foregroundStyle(active ? Color.accentColor : Color.primary).help(help).accessibilityLabel(help)
    }
}
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    let focusRequest: Int
    let submit: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "搜索或输入网址"
        field.delegate = context.coordinator
        // Ending editing must never navigate. Only an explicit Return command submits.
        field.target = nil; field.action = nil
        field.setAccessibilityLabel("地址栏")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if text.isEmpty { DispatchQueue.main.async { field.selectText(nil) } }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if !editing && field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.selectText(nil) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var lastFocus: Int
        init(_ parent: AddressField) { self.parent = parent; lastFocus = parent.focusRequest }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.editing = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.editing = false }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == NSSelectorFromString("insertNewline:") {
                if textView.hasMarkedText() { return false }
                let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return true }
                parent.text = value; parent.editing = false
                control.window?.makeFirstResponder(nil)
                parent.submit(value)
                return true
            }
            if commandSelector == NSSelectorFromString("cancelOperation:") {
                parent.editing = false; control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}
struct BrowserChrome: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(model.tabs) { tab in
                            TabLabel(tab: tab, model: model)
                                .onDrag { NSItemProvider(object: ("pagekeep-tab:" + tab.id.uuidString) as NSString) }
                                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                                    guard let provider = providers.first else { return false }
                                    _ = provider.loadObject(ofClass: String.self) { string, _ in
                                        guard let string, string.hasPrefix("pagekeep-tab:"), let id = UUID(uuidString: String(string.dropFirst(13))) else { return }
                                        DispatchQueue.main.async { AppDelegate.shared?.transfer(id, to: model, before: tab.id) }
                                    }
                                    return true
                                }
                        }
                    }.padding(.horizontal, 6)
                }
                ToolButton(symbol: "plus", help: "新建标签页 · ⌘T") { model.newTab() }.padding(.trailing, 6)
            }.frame(height: 34).background(.bar)
            Divider()
            if let tab = model.active {
                NavigationBar(tab: tab, model: model).id(tab.id)
                if model.findVisible {
                    HStack(spacing: 8) {
                        Spacer()
                        TextField("在页面中查找", text: $model.findText).textFieldStyle(.roundedBorder).frame(width: 250).onSubmit { model.find() }
                        Text(model.findResult).font(.caption).foregroundStyle(.secondary)
                        ToolButton(symbol: "chevron.up", help: "上一个") { model.find(backwards: true) }
                        ToolButton(symbol: "chevron.down", help: "下一个") { model.find() }
                        ToolButton(symbol: "xmark", help: "关闭查找") { model.findVisible = false }
                    }.padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
                }
                TabContent(tab: tab, model: model).id(tab.id)
            }
        }.frame(minWidth: 720, minHeight: 450)
            .sheet(item: $model.panel) { panel in BrowserSheet(panel: panel, model: model) }
    }
}
struct TabLabel: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 7) {
            if tab.record.sleeping { Image(systemName: "moon").foregroundStyle(.secondary) }
            else if tab.crashed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            else { Image(systemName: tab.record.pinned ? "pin.fill" : "globe").foregroundStyle(.secondary) }
            if !tab.record.pinned { Text(tab.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
            if tab.record.muted { Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
            if !tab.record.pinned {
                Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 18, height: 20) }.buttonStyle(.borderless).help("关闭标签页")
            }
        }.font(.system(size: 12)).padding(.horizontal, 9).frame(width: tab.record.pinned ? 38 : 174, height: 28)
            .background(model.selected == tab.id ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle()).onTapGesture { model.select(tab) }
            .help(tab.title).accessibilityElement(children: .contain).accessibilityLabel(tab.title)
            .contextMenu {
                Button(tab.record.pinned ? "取消固定" : "固定标签页") { model.togglePin(tab) }
                Button(tab.record.muted ? "取消静音" : "静音") { tab.toggleMute() }
                Button("移到新窗口") { model.detach(tab) }.disabled(model.tabs.count < 2)
                Divider(); Button("重新加载") { tab.reload() }; Button("关闭标签页") { model.close(tab) }
            }
    }
}
struct NavigationBar: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var model: BrowserModel
    @ObservedObject var library = LibraryStore.shared
    @State private var address: String
    @State private var addressEditing = false
    init(tab: BrowserTab, model: BrowserModel) {
        self.tab = tab; self.model = model
        _address = State(initialValue: tab.record.url == "about:blank" ? "" : tab.record.url)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ToolButton(symbol: "chevron.left", help: "后退 · ⌘[") { tab.webView?.goBack() }.disabled(!tab.canGoBack)
                ToolButton(symbol: "chevron.right", help: "前进 · ⌘]") { tab.webView?.goForward() }.disabled(!tab.canGoForward)
                ToolButton(symbol: tab.loading ? "xmark" : "arrow.clockwise", help: tab.loading ? "停止加载" : "重新加载 · ⌘R") { if tab.loading { tab.webView?.stopLoading() } else { tab.reload() } }
                HStack(spacing: 7) {
                    Image(systemName: tab.webView?.url?.scheme == "https" && tab.webView?.hasOnlySecureContent == true ? "lock" : "globe").font(.system(size: 11)).foregroundStyle(.secondary)
                    AddressField(text: $address, editing: $addressEditing, focusRequest: model.addressFocus) { model.navigate($0) }
                    if !addressEditing {
                        Button { library.bookmark(tab) } label: { Image(systemName: library.bookmarks.contains { $0.url == tab.record.url } ? "star.fill" : "star").font(.system(size: 12)) }.buttonStyle(.borderless).help("书签 · ⌘D")
                    }
                }.padding(.horizontal, 10).frame(height: 28)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)).padding(.horizontal, 5)
                ToolButton(symbol: tab.focused ? "arrow.down.right.and.arrow.up.left" : "viewfinder", help: tab.focused ? "退出专注" : "专注游戏区域", active: tab.focused) { tab.focus(tab.focused ? "off" : "on") }.disabled(tab.webView == nil)
                Menu {
                    ForEach(RunMode.allCases, id: \.self) { mode in Button { tab.setMode(mode) } label: { Label(mode.title, systemImage: tab.record.mode == mode ? "checkmark" : "circle") } }
                    Divider(); Button("运行设置与检测…") { model.panel = .runtime }
                    Button("休眠并释放内存…") { model.sleepActive() }.disabled(!tab.running)
                } label: { Label(tab.record.mode.title, systemImage: tab.record.mode == .continuous ? "bolt" : "leaf") }.menuStyle(.borderlessButton).fixedSize().frame(minWidth: 62).help("当前标签的运行模式")
                ToolButton(symbol: tab.record.muted ? "speaker.slash" : "speaker.wave.2", help: tab.record.muted ? "取消静音" : "静音", active: tab.record.muted) { tab.toggleMute() }.disabled(tab.webView == nil)
                Menu {
                    Button("书签与历史记录…") { model.panel = .library }; Button("下载…") { model.panel = .downloads }
                    Divider(); Button("选择游戏区域…") { tab.focus("pick") }; Button("开发者工具") { tab.inspect() }; Button("设置…") { model.panel = .settings }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 26) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 10).frame(height: 42).background(.bar)
            ZStack(alignment: .leading) {
                Color(nsColor: .separatorColor).opacity(0.45)
                if tab.loading { GeometryReader { size in Color.accentColor.frame(width: size.size.width * tab.progress) } }
            }.frame(height: 1)
        }.onChange(of: tab.record.url) { _, value in if !addressEditing { address = value == "about:blank" ? "" : value } }
            .onChange(of: addressEditing) { _, value in if !value { address = tab.record.url == "about:blank" ? "" : tab.record.url } }
    }
}
struct TabContent: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            if let notice = tab.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle"); Text(notice).font(.system(size: 12)).textSelection(.enabled); Spacer(minLength: 8)
                    Button { tab.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
                Divider()
            }
            if tab.crashed || tab.record.sleeping {
                VStack(spacing: 14) {
                    Image(systemName: tab.crashed ? "exclamationmark.arrow.triangle.2.circlepath" : "moon").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(tab.crashed ? "页面进程已退出" : "页面已休眠").font(.title3)
                    Text("恢复会重新加载网页。").foregroundStyle(.secondary)
                    Button("重新加载") { tab.reload() }.keyboardShortcut(.return, modifiers: [])
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let webView = tab.webView { WebSurface(webView: webView).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { NewTabView(model: model) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct NewTabView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var library = LibraryStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pagekeep").font(.system(size: 28, weight: .medium))
            Text("打开网页，或从书签开始。").font(.system(size: 14)).foregroundStyle(.secondary)
            Divider()
            Button { model.active?.navigate(URL(string: "https://games.dmm.com/")!) } label: { Label("DMM GAMES", systemImage: "globe") }.buttonStyle(.link)
            ForEach(Array(library.bookmarks.prefix(6))) { visit in Button { if let url = URL(string: visit.url) { model.active?.navigate(url) } } label: { Text(visit.title).lineLimit(1) }.buttonStyle(.link) }
        }.frame(width: 340).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}
