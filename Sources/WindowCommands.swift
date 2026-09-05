import Cocoa
import WebKit
import UniformTypeIdentifiers

extension BrowserWindow {
    func notice(_ title: String, detail: String = "") {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for:window,completionHandler:nil) } else { alert.runModal() }
    }
    func closeTab(_ id: UUID, confirm: Bool = true) {
        guard let index = tabs.firstIndex(where:{$0.id == id}) else { return }
        let tab = tabs[index]
        if confirm && tab.isSteady {
            let alert = NSAlert(); alert.messageText = "结束“\(tab.record.title)”？"
            alert.informativeText = "此标签正在常速运行。关闭后游戏会停止。"
            alert.addButton(withTitle:"结束并关闭"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closedTabs.append(tab.record); closedTabs = Array(closedTabs.suffix(30))
        tabs.remove(at:index); tab.close()
        if tabs.isEmpty { selectedID = nil; window?.close(); return }
        selectTab(selectedID == id ? tabs[min(index,tabs.count-1)].id : selectedID)
    }
    func restoreClosedTab() {
        guard var record = closedTabs.popLast() else { return }
        record.id = UUID(); adopt(BrowserTab(record:record),select:true)
    }
    func nextTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where:{$0.id == selectedID}) ?? 0
        selectTab(tabs[(index+delta+tabs.count)%tabs.count].id)
    }
    func detach(_ id: UUID) {
        guard let index = tabs.firstIndex(where:{$0.id == id}), let app = NSApp.delegate as? AppDelegate else { return }
        let tab = tabs.remove(at:index); tab.surface.removeFromSuperview()
        let destination = app.newWindow(empty:true); destination.adopt(tab,select:true)
        if tabs.isEmpty { selectedID = nil; window?.close() }
        else { selectTab(tabs[min(index,tabs.count-1)].id) }
    }
    func acceptTab(_ id: UUID, at requestedIndex: Int) {
        guard let app = NSApp.delegate as? AppDelegate, let source = app.windows.first(where:{$0.tabs.contains(where:{$0.id == id})}), let index = source.tabs.firstIndex(where:{$0.id == id}) else { return }
        let tab = source.tabs.remove(at:index)
        tab.surface.removeFromSuperview(); tab.owner = self
        tabs.insert(tab,at:min(max(0,requestedIndex),tabs.count)); root.pages.addSubview(tab.surface)
        tab.surface.frame = root.pages.bounds; selectTab(id)
        if source !== self {
            if source.tabs.isEmpty { source.selectedID = nil; source.window?.close() }
            else { source.selectTab(source.tabs[min(index,source.tabs.count-1)].id) }
        }
    }
    func dragTab(_ id: UUID, event: NSEvent, chip: NSView) {
        draggedID = id
        let item = NSDraggingItem(pasteboardWriter:NSString(string:"still-tab:"+id.uuidString))
        let image = NSImage(size:chip.bounds.size)
        image.lockFocus(); NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect:chip.bounds,xRadius:6,yRadius:6).fill()
        let title = tabs.first(where:{$0.id == id})?.record.title ?? "标签页"
        title.draw(at:NSPoint(x:12,y:8),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor]); image.unlockFocus()
        item.setDraggingFrame(chip.bounds,contents:image)
        chip.beginDraggingSession(with:[item],event:event,source:self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedID = nil }
        if operation.isEmpty, let id = draggedID { detach(id) }
    }
    func tabMenu(_ id: UUID,event: NSEvent) {
        guard let tab = tabs.first(where:{$0.id == id}) else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.command(tab.record.pinned ? "取消固定" : "固定标签") { [weak self] in
            tab.record.pinned.toggle()
            guard let self, let index = self.tabs.firstIndex(where:{$0.id == id}) else { return }
            self.tabs.remove(at:index)
            let destination = self.tabs.prefix(while:{$0.record.pinned}).count
            self.tabs.insert(tab,at:destination); self.layoutTabs(); (NSApp.delegate as? AppDelegate)?.sessionsChanged()
        }
        menu.command("复制标签页",enabled:tab.url != nil) { [weak self] in self?.newTab(url:tab.url) }
        menu.command("移到新窗口") { [weak self] in self?.detach(id) }
        menu.addItem(.separator())
        menu.command(tab.record.preferences.mute ? "取消静音" : "静音") { tab.setMuted(!tab.record.preferences.mute) }
        menu.command(tab.record.sleeping ? "恢复标签页" : "休眠并释放内存") { [weak self] in
            if tab.record.sleeping { tab.wake() } else { self?.confirmSleep(tab) }
        }
        menu.addItem(.separator()); menu.command("关闭标签页") { [weak self] in self?.closeTab(id) }
        NSMenu.popUpContextMenu(menu,with:event,for:root.strip)
    }
    func reloadOrStop() {
        guard let tab = current else { return }
        if tab.record.sleeping { tab.wake(); return }
        if tab.webView?.isLoading == true { tab.webView?.stopLoading() }
        else { tab.failure = nil; tab.surface.placeholder?.removeFromSuperview(); tab.surface.placeholder = nil; tab.webView?.reload() }
    }
    func hardReload() { current?.webView?.reloadFromOrigin() }
    func confirmSleep(_ tab: BrowserTab) {
        let alert = NSAlert(); alert.messageText = "休眠“\(tab.record.title)”？"
        alert.informativeText = "这会卸载页面以释放内存。游戏将停止，恢复时需要重新加载，未保存的状态可能丢失。\n\n只想降低后台消耗，请选择“节能”，无需重载。"
        alert.addButton(withTitle:"休眠"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn { tab.sleep() }
    }
    @objc func showRunMenu() {
        guard let tab = current else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.command("常速",checked:tab.isSteady,enabled:!tab.record.sleeping) { tab.setMode(.steady) }
        menu.command("节能",checked:!tab.record.sleeping && tab.record.preferences.mode == .economy,enabled:!tab.record.sleeping) { tab.setMode(.economy) }
        let explanation = NSMenuItem(title:"节能允许后台变慢或暂停，不卸载页面",action:nil,keyEquivalent:""); explanation.isEnabled = false; menu.addItem(explanation)
        menu.addItem(.separator())
        menu.command(tab.record.sleeping ? "恢复标签页" : "休眠并释放内存…") { [weak self] in
            if tab.record.sleeping { tab.wake() } else { self?.confirmSleep(tab) }
        }
        menu.command("运行诊断…",enabled:tab.webView != nil) { DiagnosticPanel.shared.show(tab) }
        menu.addItem(.separator())
        menu.command("所有标签切为节能") { [weak self] in self?.tabs.forEach { $0.setMode(.economy) } }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:runButton.bounds.maxY+4),in:runButton)
    }
    func focusMenu() {
        guard let tab = current else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.command("自动识别并专注",checked:tab.record.preferences.autoFocus) { tab.toggleFocus() }
        menu.command("手动选择游戏区域…") { [weak self] in self?.selectRegion() }
        menu.command("显示完整页面",enabled:tab.focused || tab.record.preferences.autoFocus) {
            tab.record.preferences.autoFocus = false; tab.surface.focus(nil); tab.applyPolicy()
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:focusButton.bounds.maxY+4),in:focusButton)
    }
    func selectRegion() {
        guard let tab = current, tab.webView != nil else { return }
        tab.record.preferences.autoFocus = false; tab.focusRequest += 1; tab.surface.focus(nil)
        tab.surface.layoutSubtreeIfNeeded()
        let overlay = RegionSelector(frame:tab.surface.bounds)
        overlay.autoresizingMask = [.width,.height]
        overlay.complete = { [weak self, weak tab] rect in
            if let tab, let rect { tab.surface.focus(rect,viewport:tab.surface.bounds.size) }
            self?.window?.makeFirstResponder(tab?.webView); self?.refreshChrome()
        }
        tab.surface.addSubview(overlay); window?.makeFirstResponder(overlay)
    }
    func moreMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.command("添加 / 移除书签",key:"d") { [weak self] in self?.bookmark() }
        menu.command("在页面中查找…",key:"f") { [weak self] in self?.showFind() }
        menu.addItem(.separator())
        menu.command("放大",key:"+") { [weak self] in self?.zoom(0.1) }
        menu.command("缩小",key:"-") { [weak self] in self?.zoom(-0.1) }
        menu.command("实际大小",key:"0") { [weak self] in self?.zoom(0,reset:true) }
        menu.addItem(.separator())
        menu.command("开发者工具",key:"i",modifiers:[.command,.option]) { [weak self] in self?.current?.inspect() }
        menu.command("控制台") { [weak self] in self?.current?.inspect("showConsole") }
        menu.command("元素选择器") { [weak self] in self?.current?.inspect("toggleElementSelection") }
        menu.addItem(.separator())
        menu.command("保存网页…") { [weak self] in self?.savePage() }
        menu.command("保存页面截图…") { [weak self] in self?.saveScreenshot() }
        menu.command("打印…",key:"p") { [weak self] in self?.printPage() }
        menu.addItem(.separator())
        menu.command("允许此页面自动弹出窗口",checked:current?.record.preferences.allowPopups == true) { [weak self] in
            guard let tab = self?.current else { return }; tab.record.preferences.allowPopups.toggle(); tab.applyPolicy()
        }
        menu.command("复制页面地址") { [weak self] in guard let text = self?.current?.record.url else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
        menu.command("设置…",key:",") { SettingsPanel.shared.show() }
        menu.popUp(positioning:nil,at:NSPoint(x:root.bounds.width-32,y:0),in:root)
    }
    func bookmark() {
        guard let tab = current else { return }
        BrowserStore.shared.toggleBookmark(title:tab.record.title,url:tab.url); library.refresh(); refreshAddressCompletions()
    }
    func zoom(_ increment: Double, reset: Bool = false) {
        guard let tab = current else { return }
        tab.surface.focus(nil)
        tab.record.preferences.zoom = reset ? 1 : min(3,max(0.25,tab.record.preferences.zoom+increment))
        tab.applyPolicy()
    }
    func configureFindBar() {
        findField.frame = NSRect(x:14,y:5,width:320,height:26); findField.autoresizingMask = .maxXMargin
        findField.placeholderString = "在页面中查找"; findField.target = self; findField.action = #selector(findForward)
        findField.sendsSearchStringImmediately = true; root.findBar.addSubview(findField)
        let previous = ActionButton(symbol:"chevron.up",help:"上一个匹配项") { [weak self] in self?.find(backwards:true) }
        let next = ActionButton(symbol:"chevron.down",help:"下一个匹配项") { [weak self] in self?.find() }
        let close = ActionButton(symbol:"xmark",help:"关闭查找") { [weak self] in self?.hideFind() }
        for (index,button) in [previous,next,close].enumerated() { button.frame = NSRect(x:CGFloat(344+index*30),y:4,width:28,height:28); root.findBar.addSubview(button) }
        findStatus.frame = NSRect(x:444,y:8,width:220,height:20); findStatus.textColor = .secondaryLabelColor; findStatus.font = .systemFont(ofSize:12); root.findBar.addSubview(findStatus)
    }
    func showFind() { root.finding = true; root.needsLayout = true; window?.makeFirstResponder(findField) }
    func hideFind() { root.finding = false; root.needsLayout = true; window?.makeFirstResponder(current?.webView) }
    @objc func findForward() { find() }
    func find(backwards: Bool = false) {
        guard !findField.stringValue.isEmpty, let view = current?.webView else { findStatus.stringValue = ""; return }
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true
        view.find(findField.stringValue,configuration:configuration) { [weak self] result in self?.findStatus.stringValue = result.matchFound ? "" : "未找到匹配项" }
    }
    func siteInformation() {
        guard let tab = current else { return }
        let secure = tab.url?.scheme == "https" && tab.webView?.hasOnlySecureContent == true
        notice(secure ? "此页面使用安全连接" : "网站信息",detail:Address.redacted(tab.url)+"\n\n登录和站点数据保存在 Still 内，不读取其他浏览器的数据。")
    }
    func showPlaceholder(for tab: BrowserTab) {
        let heading: String, detail: String, buttonTitle: String
        if tab.record.sleeping { heading = "标签已休眠"; detail = "页面已卸载。恢复时会重新加载。"; buttonTitle = "恢复标签页" }
        else if let failure = tab.failure { heading = "页面未能继续运行"; detail = failure; buttonTitle = "重新加载" }
        else { heading = "新标签页"; detail = "输入地址，或打开收藏的游戏。"; buttonTitle = "打开 DMM GAMES" }
        let title = caption(heading,size:23); title.font = .systemFont(ofSize:23,weight:.medium)
        let sub = caption(detail,size:13,secondary:true)
        let button = NSButton(title:buttonTitle,target:nil,action:nil)
        let command = MenuCommand { [weak tab] in
            guard let tab else { return }
            if tab.record.sleeping { tab.wake() }
            else if tab.failure != nil {
                tab.failure = nil; tab.surface.placeholder?.removeFromSuperview(); tab.surface.placeholder = nil
                if let url = tab.url { tab.navigate(to:url) }
            } else if let url = URL(string:"https://games.dmm.com/") { tab.navigate(to:url) }
        }
        button.target = command; button.action = #selector(MenuCommand.invoke); button.bezelStyle = .rounded
        let box = RetainedPanel(views:[title,sub,button]); box.retainedObjects = [command]
        tab.surface.showPlaceholder(box)
    }
    func savePage() {
        guard let view = current?.webView else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "页面.webarchive"
        if let type = UTType(filenameExtension:"webarchive") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        view.createWebArchiveData { [weak self] result in
            do { let data = try result.get(); try data.write(to:url,options:.atomic) }
            catch { self?.notice("保存失败",detail:error.localizedDescription) }
        }
    }
    func saveScreenshot() {
        guard let view = current?.webView else { return }
        let configuration = WKSnapshotConfiguration(); configuration.rect = current?.surface.region ?? view.bounds
        let panel = NSSavePanel(); panel.nameFieldStringValue = "页面.png"; panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        view.takeSnapshot(with:configuration) { [weak self] image,error in
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let data = bitmap.representation(using:.png,properties:[:]) else { self?.notice("截图失败",detail:error?.localizedDescription ?? "无法读取页面画面"); return }
            do { try data.write(to:url,options:.atomic) } catch { self?.notice("保存失败",detail:error.localizedDescription) }
        }
    }
    func printPage() { current?.webView?.printOperation(with:NSPrintInfo.shared).run() }
}

@MainActor final class RetainedPanel: NSStackView {
    var retainedObjects: [AnyObject] = []
    init(views: [NSView]) {
        super.init(frame:.zero); orientation = .vertical; alignment = .leading; spacing = 14
        views.forEach { addArrangedSubview($0) }; widthAnchor.constraint(lessThanOrEqualToConstant:560).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}
@MainActor final class RegionSelector: FlippedView {
    var origin: NSPoint?; var selection = NSRect.zero
    var complete: ((NSRect?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ rect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()
        if !selection.isEmpty { NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect:selection); path.lineWidth = 2; path.stroke() }
        "拖动选择游戏区域 · Esc 取消".draw(at:NSPoint(x:18,y:18),withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor.labelColor,.backgroundColor:NSColor.windowBackgroundColor])
    }
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow,from:nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }; let point = convert(event.locationInWindow,from:nil)
        selection = NSRect(x:min(origin.x,point.x),y:min(origin.y,point.y),width:abs(origin.x-point.x),height:abs(origin.y-point.y)).intersection(bounds); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { let result = selection.width >= 100 && selection.height >= 70 ? selection : nil; removeFromSuperview(); complete?(result) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { removeFromSuperview(); complete?(nil) } else { super.keyDown(with:event) } }
}
