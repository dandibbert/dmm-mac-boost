import Cocoa
import WebKit

@MainActor final class BrowserRoot: FlippedView {
    let strip = TabStripView()
    let tabScroll = NSScrollView()
    let findBar = FlippedView()
    let body = FlippedView()
    let pages = FlippedView()
    let sidebar = FlippedView()
    let progress = NSProgressIndicator()
    var sidebarVisible = false
    var finding = false
    override init(frame: NSRect) {
        super.init(frame:frame)
        tabScroll.documentView = strip; tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true; tabScroll.drawsBackground = false
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        addSubview(tabScroll); addSubview(findBar); addSubview(body); addSubview(progress)
        body.addSubview(sidebar); body.addSubview(pages)
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); let w = bounds.width, h = bounds.height
        tabScroll.frame = NSRect(x:8,y:2,width:max(0,w-16),height:34)
        progress.frame = NSRect(x:0,y:36,width:w,height:2)
        findBar.isHidden = !finding; findBar.frame = NSRect(x:0,y:38,width:w,height:finding ? 36 : 0)
        let top: CGFloat = finding ? 74 : 38
        body.frame = NSRect(x:0,y:top,width:w,height:max(0,h-top))
        let side: CGFloat = sidebarVisible ? 234 : 0
        sidebar.isHidden = !sidebarVisible; sidebar.frame = NSRect(x:0,y:0,width:side,height:body.bounds.height)
        pages.frame = NSRect(x:side,y:0,width:max(0,w-side),height:body.bounds.height)
        for view in pages.subviews { view.frame = pages.bounds }
        for view in sidebar.subviews { view.frame = sidebar.bounds }
    }
}
@MainActor final class TabStripView: FlippedView {
    weak var owner: BrowserWindow?
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([.string]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType:.string)?.hasPrefix("still-tab:") == true ? .move : []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let value = sender.draggingPasteboard.string(forType:.string), value.hasPrefix("still-tab:"), let id = UUID(uuidString:String(value.dropFirst(10))) else { return false }
        let point = convert(sender.draggingLocation,from:nil)
        owner?.acceptTab(id,at:max(0,Int(point.x / 186)))
        return true
    }
}

@MainActor final class BrowserWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSComboBoxDelegate, NSDraggingSource {
    let identity: UUID
    let root = BrowserRoot(frame:NSRect(x:0,y:0,width:1240,height:820))
    var tabs: [BrowserTab] = []
    var selectedID: UUID?
    var closedTabs: [TabRecord] = []
    var draggedID: UUID?
    var library: LibraryPanel!
    var current: BrowserTab? { tabs.first { $0.id == selectedID } }
    let address = NSComboBox(frame:NSRect(x:0,y:0,width:480,height:28))
    let security = ActionButton(symbol:"lock",help:"网站信息",action:{})
    let back = ActionButton(symbol:"chevron.left",help:"后退",action:{})
    let forward = ActionButton(symbol:"chevron.right",help:"前进",action:{})
    let reloadButton = ActionButton(symbol:"arrow.clockwise",help:"刷新 / 停止",action:{})
    let focusButton = ActionButton(symbol:"viewfinder",help:"专注游戏区域",action:{})
    let muteButton = ActionButton(symbol:"speaker.wave.2",help:"标签静音",action:{})
    let runButton = NSButton(title:"节能",target:nil,action:nil)
    let findField = NSSearchField()
    let findStatus = NSTextField(labelWithString:"")
    var addressEditing = false

    init(record: WindowRecord? = nil, empty: Bool = false) {
        identity = record?.id ?? UUID()
        let window = BrowserNativeWindow(contentRect:NSRect(x:0,y:0,width:1240,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title = "Still"; window.titleVisibility = .hidden; window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width:800,height:500); window.delegate = self
        window.contentView = root; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Still-"+identity.uuidString); window.center()
        root.strip.owner = self
        let toolbar = NSToolbar(identifier:"Still.Toolbar"); toolbar.delegate = self
        toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        library = LibraryPanel(owner:self); root.sidebar.addSubview(library.view)
        configureFindBar()
        address.delegate = self; address.target = self; address.action = #selector(navigateAddress)
        address.font = .systemFont(ofSize:13); address.placeholderString = "搜索或输入网站地址"
        address.completes = true; address.numberOfVisibleItems = 12
        address.usesDataSource = false; address.setAccessibilityLabel("地址栏")
        back.handler = { [weak self] in self?.current?.webView?.goBack() }
        forward.handler = { [weak self] in self?.current?.webView?.goForward() }
        reloadButton.handler = { [weak self] in self?.reloadOrStop() }
        focusButton.handler = { [weak self] in self?.focusMenu() }
        muteButton.handler = { [weak self] in guard let tab = self?.current else { return }; tab.setMuted(!tab.record.preferences.mute) }
        security.handler = { [weak self] in self?.siteInformation() }
        runButton.target = self; runButton.action = #selector(showRunMenu)
        runButton.bezelStyle = .texturedRounded; runButton.controlSize = .small
        if let record {
            for value in record.tabs { adopt(BrowserTab(record:value),select:false) }
            selectTab(record.selected ?? tabs.first?.id)
        } else if !empty { newTab() }
        refreshAddressCompletions(); refreshChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    var snapshot: WindowRecord { WindowRecord(id:identity,tabs:tabs.map(\.record),selected:selectedID) }
    @discardableResult func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, load: Bool = true, select: Bool = true) -> BrowserTab {
        var record = TabRecord()
        if let url { record.url = url.absoluteString; record.title = url.host ?? "新标签页"; record.preferences = BrowserStore.shared.preferences(for:url) }
        let tab = BrowserTab(record:record,configuration:configuration,load:load)
        adopt(tab,select:select); return tab
    }
    func adopt(_ tab: BrowserTab,select: Bool) {
        tab.owner = self; tabs.append(tab); root.pages.addSubview(tab.surface)
        tab.surface.frame = root.pages.bounds
        if tab.record.url.isEmpty || tab.record.sleeping { showPlaceholder(for:tab) }
        if select || selectedID == nil { selectedID = tab.id }
        layoutTabs(); selectTab(selectedID)
    }
    func selectTab(_ id: UUID?) {
        guard let id, let selected = tabs.first(where:{$0.id == id}) else { return }
        selectedID = id
        for tab in tabs { tab.surface.isHidden = tab.id != id && !tab.isSteady }
        root.pages.addSubview(selected.surface,positioned:.above,relativeTo:nil)
        layoutTabs(); refreshChrome(); (NSApp.delegate as? AppDelegate)?.sessionsChanged()
    }
    func tabDidChange(_ tab: BrowserTab) {
        tab.surface.isHidden = tab.id != selectedID && !tab.isSteady
        layoutTabs(); refreshChrome(); library?.refresh()
        (NSApp.delegate as? AppDelegate)?.sessionsChanged()
    }
    func layoutTabs() {
        root.strip.subviews.forEach { $0.removeFromSuperview() }
        for (index,tab) in tabs.enumerated() {
            let chip = TabChip(id:tab.id) { [weak self] in self?.closeTab(tab.id) }
            chip.frame = NSRect(x:index*186,y:0,width:180,height:32)
            chip.label.stringValue = tab.record.title; chip.selected = tab.id == selectedID
            let symbol = tab.record.sleeping ? "moon" : tab.record.preferences.mute ? "speaker.slash" : tab.record.pinned ? "pin" : tab.isSteady ? "play.circle" : "globe"
            chip.glyph.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
            chip.toolTip = tab.record.title+"\n"+Address.redacted(tab.url)
            chip.setAccessibilityLabel(tab.record.title)
            chip.select = { [weak self] in self?.selectTab(tab.id) }
            chip.showMenu = { [weak self] event in self?.tabMenu(tab.id,event:event) }
            chip.startDrag = { [weak self, weak chip] event in if let chip { self?.dragTab(tab.id,event:event,chip:chip) } }
            root.strip.addSubview(chip)
        }
        let plus = ActionButton(symbol:"plus",help:"新建标签页 ⌘T") { [weak self] in self?.newTab(); self?.focusAddress() }
        plus.frame = NSRect(x:tabs.count*186+2,y:2,width:30,height:28); root.strip.addSubview(plus)
        root.strip.frame = NSRect(x:0,y:0,width:max(root.tabScroll.contentSize.width,CGFloat(tabs.count*186+40)),height:32)
    }
    func refreshChrome() {
        guard isWindowLoaded else { return }
        let tab = current, view = tab?.webView
        if address.currentEditor() == nil { address.stringValue = tab?.record.url ?? "" }
        back.isEnabled = view?.canGoBack ?? false; forward.isEnabled = view?.canGoForward ?? false
        reloadButton.image = NSImage(systemSymbolName:view?.isLoading == true ? "xmark" : "arrow.clockwise",accessibilityDescription:nil)
        focusButton.contentTintColor = tab?.focused == true ? .controlAccentColor : .secondaryLabelColor
        muteButton.image = NSImage(systemSymbolName:tab?.record.preferences.mute == true ? "speaker.slash" : "speaker.wave.2",accessibilityDescription:nil)
        muteButton.isEnabled = view != nil; focusButton.isEnabled = view != nil && !(tab?.record.url.isEmpty ?? true)
        runButton.title = tab?.record.sleeping == true ? "休眠" : tab?.isSteady == true ? "常速" : "节能"
        runButton.toolTip = "当前标签的运行模式；不会刷新页面"
        root.progress.doubleValue = view?.estimatedProgress ?? 0
        root.progress.isHidden = view?.isLoading != true
        window?.title = (tab?.record.title ?? "新标签页")+" — Still"
        security.image = NSImage(systemSymbolName:view?.hasOnlySecureContent == true && tab?.url?.scheme == "https" ? "lock" : "info.circle",accessibilityDescription:nil)
    }
    func refreshAddressCompletions() {
        address.removeAllItems()
        var seen = Set<String>()
        let items = (BrowserStore.shared.state.bookmarks+BrowserStore.shared.state.history).filter { seen.insert($0.url).inserted }.prefix(100)
        address.addItems(withObjectValues:items.map(\.url))
    }
    @objc func navigateAddress() {
        guard let url = Address.resolve(address.stringValue,searchEngine:BrowserStore.shared.state.settings.searchEngine) else { NSSound.beep(); return }
        if current == nil { newTab() }
        current?.navigate(to:url); window?.makeFirstResponder(current?.webView)
    }
    func focusAddress() { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(address); address.selectText(nil) }
    func controlTextDidEndEditing(_ obj: Notification) { refreshChrome() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let value = address.objectValueOfSelectedItem as? String { address.stringValue = value; navigateAddress() }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar)+[.space] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("library"),.init("navigation"),.flexibleSpace,.init("address"),.flexibleSpace,.init("focus"),.init("run"),.init("mute"),.init("downloads"),.init("more")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier:identifier)
        switch identifier.rawValue {
        case "navigation":
            let group = NSView(frame:NSRect(x:0,y:0,width:90,height:28))
            for (i,button) in [back,forward,reloadButton].enumerated() { button.frame = NSRect(x:i*30,y:0,width:28,height:28); group.addSubview(button) }
            item.view = group; item.label = "导航"
        case "address":
            let group = NSView(frame:NSRect(x:0,y:0,width:500,height:28))
            security.frame = NSRect(x:0,y:0,width:26,height:28)
            address.frame = NSRect(x:28,y:0,width:472,height:28); address.autoresizingMask = .width
            group.addSubview(security); group.addSubview(address); item.view = group
            item.minSize = NSSize(width:220,height:28); item.maxSize = NSSize(width:1100,height:28); item.label = "地址栏"
        case "focus": item.view = focusButton; item.label = "专注"
        case "run": item.view = runButton; item.label = "运行模式"
        case "mute": item.view = muteButton; item.label = "静音"
        case "library": item.view = ActionButton(symbol:"sidebar.left",help:"书签与历史记录") { [weak self] in self?.toggleSidebar() }; item.label = "侧栏"
        case "downloads": item.view = ActionButton(symbol:"arrow.down.circle",help:"下载") { DownloadManager.shared.show() }; item.label = "下载"
        case "more": item.view = ActionButton(symbol:"ellipsis.circle",help:"更多页面操作") { [weak self] in self?.moreMenu() }; item.label = "更多"
        default: return nil
        }
        if identifier.rawValue != "address" && identifier.rawValue != "navigation" { item.view?.frame = NSRect(x:0,y:0,width:identifier.rawValue == "run" ? 62 : 28,height:28) }
        return item
    }
    func toggleSidebar() { root.sidebarVisible.toggle(); root.needsLayout = true; library.refresh() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if (NSApp.delegate as? AppDelegate)?.quitting == true { return true }
        let count = tabs.filter(\.isSteady).count
        guard count > 0 else { return true }
        let alert = NSAlert(); alert.messageText = "结束此窗口中的 \(count) 个常速标签？"
        alert.informativeText = "关闭窗口会结束这些页面。要继续后台运行，请最小化或切换到其他窗口。"
        alert.addButton(withTitle:"结束并关闭"); alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.close() }; tabs.removeAll()
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }
    func windowDidBecomeKey(_ notification: Notification) { (NSApp.delegate as? AppDelegate)?.activeWindow = self; refreshAddressCompletions() }
    func windowDidResize(_ notification: Notification) { root.needsLayout = true; layoutTabs() }
}
