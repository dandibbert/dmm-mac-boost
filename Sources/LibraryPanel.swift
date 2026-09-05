import Cocoa

@MainActor final class LibraryPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: BrowserWindow?
    let search = NSSearchField()
    let segment = NSSegmentedControl(labels:["书签","历史记录"],trackingMode:.selectOne,target:nil,action:nil)
    let table = NSTableView()
    let scroll = NSScrollView()
    let empty = NSTextField(labelWithString:"还没有书签")
    var pages: [SavedPage] = []
    init(owner: BrowserWindow) { self.owner = owner; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = LibraryRoot(frame:NSRect(x:0,y:0,width:234,height:700))
        view = root
        segment.selectedSegment = 0; segment.target = self; segment.action = #selector(filterChanged)
        segment.controlSize = .small; root.addSubview(segment)
        search.placeholderString = "筛选"; search.target = self; search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true; root.addSubview(search)
        let column = NSTableColumn(identifier:.init("page")); column.width = 220
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 48
        table.style = .sourceList; table.intercellSpacing = NSSize(width:0,height:2)
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(activateSelectedPage)
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.command("打开") { [weak self] in self?.activateSelectedPage() }
        menu.command("在新标签页打开") { [weak self] in self?.openSelected(newTab:true) }
        menu.command("移除记录") { [weak self] in self?.removeSelected() }
        table.menu = menu
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        root.addSubview(scroll); empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize:12); root.addSubview(empty)
        let add = ActionButton(symbol:"plus",help:"收藏当前页面") { [weak self] in self?.owner?.bookmark() }
        root.addSubview(add)
        root.onLayout = { [weak self, weak add] size in
            guard let self else { return }
            self.segment.frame = NSRect(x:12,y:14,width:size.width-24,height:26)
            self.search.frame = NSRect(x:12,y:50,width:size.width-24,height:26)
            self.scroll.frame = NSRect(x:5,y:88,width:size.width-10,height:max(0,size.height-126))
            self.empty.frame = NSRect(x:18,y:112,width:size.width-36,height:22)
            add?.frame = NSRect(x:10,y:max(90,size.height-32),width:24,height:24)
        }
        refresh()
    }
    @objc func filterChanged() { refresh() }
    func refresh() {
        guard isViewLoaded else { return }
        let all = segment.selectedSegment == 0 ? BrowserStore.shared.state.bookmarks : BrowserStore.shared.state.history
        let query = search.stringValue
        pages = all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
        empty.stringValue = query.isEmpty ? (segment.selectedSegment == 0 ? "用 ⌘D 收藏当前页面" : "浏览记录会显示在这里") : "没有匹配结果"
        empty.isHidden = !pages.isEmpty; table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = pages[row], cell = NSTableCellView(frame:NSRect(x:0,y:0,width:220,height:48))
        let title = NSTextField(labelWithString:page.title); title.font = .systemFont(ofSize:12,weight:.medium)
        title.lineBreakMode = .byTruncatingTail; title.frame = NSRect(x:10,y:24,width:196,height:18); title.autoresizingMask = .width
        let subtitle = NSTextField(labelWithString:URL(string:page.url)?.host ?? page.url)
        subtitle.font = .systemFont(ofSize:11); subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail; subtitle.frame = NSRect(x:10,y:7,width:196,height:16); subtitle.autoresizingMask = .width
        cell.addSubview(title); cell.addSubview(subtitle); cell.textField = title; cell.toolTip = page.url
        return cell
    }
    @objc func activateSelectedPage() { openSelected(newTab:false) }
    func openSelected(newTab: Bool) {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard pages.indices.contains(index), let url = URL(string:pages[index].url) else { return }
        if newTab || NSEvent.modifierFlags.contains(.command) { owner?.newTab(url:url) }
        else { owner?.current?.navigate(to:url) }
    }
    func removeSelected() {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard pages.indices.contains(index) else { return }
        let id = pages[index].id
        if segment.selectedSegment == 0 { BrowserStore.shared.state.bookmarks.removeAll { $0.id == id } }
        else { BrowserStore.shared.state.history.removeAll { $0.id == id } }
        BrowserStore.shared.scheduleSave(); refresh(); owner?.refreshAddressCompletions()
    }
}
@MainActor final class LibraryRoot: FlippedView {
    var onLayout: ((NSSize) -> Void)?
    override func layout() { super.layout(); onLayout?(bounds.size) }
}
