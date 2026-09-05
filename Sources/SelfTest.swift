import Cocoa
import WebKit

@MainActor final class SelfTest {
    let app: AppDelegate
    let output: URL
    var checks: [[String:Any]] = []
    var metrics: [String:Any] = [:]
    var failures = 0
    init(app: AppDelegate,output: URL) { self.app = app; self.output = output }
    func check(_ name: String,_ condition: Bool) {
        checks.append(["name":name,"passed":condition]); if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)"); fflush(stdout)
    }
    func start() {
        Task { @MainActor in
            do { try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true); try await run() }
            catch { checks.append(["name":"integration error","passed":false,"error":error.localizedDescription]); failures += 1 }
            finish()
        }
    }
    func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
    func evaluate(_ view: WKWebView,_ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source) { result,error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:result) }
            }
        }
    }
    func counters(_ view: WKWebView) async -> [String:Double] {
        (try? await evaluate(view,"({frames:fixture.frames,timers:fixture.timers})")) as? [String:Double] ?? [:]
    }
    func measure(_ view: WKWebView,seconds: Double = 4) async -> [String:Double] {
        let before = await counters(view), start = Date(); await wait(seconds)
        let after = await counters(view), elapsed = Date().timeIntervalSince(start)
        return ["fps":((after["frames"] ?? 0)-(before["frames"] ?? 0))/elapsed,"timerHz":((after["timers"] ?? 0)-(before["timers"] ?? 0))/elapsed]
    }
    func capture(_ controller: BrowserWindow,name: String) async -> Bool {
        controller.window?.makeKeyAndOrderFront(nil)
        controller.root.layoutSubtreeIfNeeded(); controller.window?.displayIfNeeded()
        await wait(0.7)
        let file = output.appendingPathComponent(name+".png")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        process.arguments = ["-x","-l",String(controller.window?.windowNumber ?? 0),file.path]
        do { try process.run(); process.waitUntilExit() } catch { return false }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf:file), let image = NSBitmapImageRep(data:data) else { return false }
        // A nonnil WKSnapshot does not prove it is visible in the actual window.
        // Sample the composited WindowServer image for the fixture's dark canvas.
        var dark = 0, samples = 0
        for y in stride(from:80,to:image.pixelsHigh,by:12) {
            for x in stride(from:20,to:image.pixelsWide-20,by:12) {
                if let color = image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) {
                    samples += 1
                    if color.redComponent < 0.35 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { dark += 1 }
                }
            }
        }
        metrics[name+"DarkPixelRatio"] = Double(dark)/Double(max(1,samples))
        return samples > 0 && dark > samples/8
    }
    func geometry(_ tab: BrowserTab) -> [String:Any] {
        ["surfaceFrame":NSStringFromRect(tab.surface.frame),"surfaceBounds":NSStringFromRect(tab.surface.bounds),
         "clipFrame":NSStringFromRect(tab.surface.plane.frame),"clipBounds":NSStringFromRect(tab.surface.plane.bounds),
         "webFrame":NSStringFromRect(tab.webView?.frame ?? .zero),"webBounds":NSStringFromRect(tab.webView?.bounds ?? .zero),
         "visibleRect":NSStringFromRect(tab.webView?.visibleRect ?? .zero),"hidden":tab.surface.isHidden,
         "windowVisible":tab.owner?.window?.isVisible ?? false,"miniaturized":tab.owner?.window?.isMiniaturized ?? false]
    }
    func run() async throws {
        check("Address resolves HTTPS hostname",Address.resolve("example.com")?.absoluteString == "https://example.com")
        check("Address accepts localhost port",Address.resolve("localhost:8080/test")?.absoluteString == "http://localhost:8080/test")
        check("Address rejects executable scheme",Address.resolve("javascript:alert(1)") == nil)
        check("DMM origin boundary",!Address.isDMM(URL(string:"https://evildmm.com/")))
        check("Diagnostic URL redaction",Address.redacted(URL(string:"https://user:password@example.com/game?token=secret#private")) == "https://example.com/game")
        let decoded = try JSONDecoder().decode(PersistentState.self,from:JSONEncoder().encode(PersistentState()))
        check("Settings JSON round trip",decoded.version == 1 && decoded.windows.isEmpty)
        let controller = app.newWindow(empty:true), tab = controller.newTab(load:false)
        guard let fixture = Bundle.main.url(forResource:"Fixture",withExtension:"html"), let view = tab.webView else { throw NSError(domain:"StillTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing fixture or WebView"]) }
        tab.navigate(to:fixture); tab.setMode(.steady); NSApp.activate(ignoringOtherApps:true)
        var ready = false
        for _ in 0..<100 {
            if (try? await evaluate(view,"typeof fixture === 'object' && fixture.frames > 0")) as? Bool == true { ready = true; break }
            await wait(0.1)
        }
        check("WebKit loads and runs local canvas",ready); guard ready else { return }
        check("Actual browser window displays canvas",await capture(controller,name:"browser-before"))
        metrics["initialGeometry"] = geometry(tab)
        let identity = try await evaluate(view,"fixture.identity") as? String, generation = tab.documentGeneration
        for _ in 0..<10 { tab.setMode(.economy); tab.setMode(.steady) }
        await wait(0.5)
        let afterIdentity = try await evaluate(view,"fixture.identity") as? String
        check("Twenty policy changes preserve document",identity == afterIdentity && generation == tab.documentGeneration && tab.webView === view)
        check("Native mute supported",STSetMuted(view,true))
        check("Native audio bit applied",STGetMuted(view))
        check("Native unmute supported",STSetMuted(view,false) && !STGetMuted(view))
        let region = try await evaluate(view,RuntimeEnvironment.viewport) as? [String:Double]
        check("Game detector returns canvas",(region?["width"] ?? 0) >= 320)
        if let region,let x = region["x"],let y = region["y"],let width = region["width"],let height = region["height"] {
            tab.surface.focus(NSRect(x:x,y:y,width:width,height:height),viewport:view.bounds.size)
            check("Native focus retains the original WebView",tab.focused && view.superview === tab.surface.plane)
            check("Focused game is visible on screen",await capture(controller,name:"browser-focused"))
            metrics["focusGeometry"] = geometry(tab)
            tab.surface.focus(nil)
        }
        let focusIdentity = try await evaluate(view,"fixture.identity") as? String
        check("Focus round trip preserves game",focusIdentity == identity)
        check("Leaving focus restores visible webpage",await capture(controller,name:"browser-restored"))
        let findResult: Bool = await withCheckedContinuation { continuation in
            view.find("Still Browser Test Marker",configuration:WKFindConfiguration()) { continuation.resume(returning:$0.matchFound) }
        }
        check("Native page find",findResult)
        let foreground = await measure(view); metrics["foreground"] = foreground
        let second = controller.newTab()
        check("Selecting another tab retains running WebView",tab.webView === view && view.superview != nil && !tab.surface.isHidden)
        let background = await measure(view); metrics["backgroundTab"] = background
        controller.selectTab(tab.id); controller.window?.miniaturize(nil); await wait(0.8)
        metrics["minimizedGeometry"] = geometry(tab)
        let minimized = await measure(view); metrics["minimized"] = minimized
        let baseline = max(1,foreground["fps"] ?? 1)
        metrics["backgroundFrameRatio"] = (background["fps"] ?? 0)/baseline
        metrics["minimizedFrameRatio"] = (minimized["fps"] ?? 0)/baseline
        check("Background tab animation matches foreground",(background["fps"] ?? 0) >= baseline*0.95)
        check("Minimized animation matches foreground",(minimized["fps"] ?? 0) >= baseline*0.95)
        // Exercise the actual scheduling change while the window is minimized.
        tab.setMode(.economy); await wait(0.6)
        metrics["minimizedEconomy"] = await measure(view,seconds:2)
        tab.setMode(.steady); await wait(0.6)
        let resumed = await measure(view,seconds:3); metrics["minimizedResumed"] = resumed
        check("Steady resumes without foregrounding or reload",(resumed["fps"] ?? 0) >= baseline*0.90)
        controller.window?.deminiaturize(nil); controller.window?.makeKeyAndOrderFront(nil); await wait(0.5)
        check("Minimize and hot switching preserve game",(try? await evaluate(view,"fixture.identity")) as? String == identity)
        controller.closeTab(second.id,confirm:false)
        check("Closing another tab keeps original game",tab.webView === view && !tab.isClosed)
        check("Developer inspector entry point",STInspector(view,"show")); await wait(0.5)
        _ = STInspector(view,"close"); await wait(0.5)
        check("Inspector does not reload game",(try? await evaluate(view,"fixture.identity")) as? String == identity)
        check("Actual game remains visible after inspector",await capture(controller,name:"browser-final"))
        metrics["finalGeometry"] = geometry(tab)
        metrics["nativeCapabilities"] = tab.capabilities.mapValues(\.boolValue)
        let image: NSImage? = await withCheckedContinuation { continuation in view.takeSnapshot(with:nil) { image,_ in continuation.resume(returning:image) } }
        if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) {
            try png.write(to:output.appendingPathComponent("web-content.png")); check("WebKit snapshot",true)
        } else { check("WebKit snapshot",false) }
        tab.sleep(); check("Explicit sleep releases WebView",tab.webView == nil && tab.record.sleeping)
        tab.wake(); check("Explicit wake recreates WebView",tab.webView != nil && !tab.record.sleeping)
    }
    func finish() {
        let report: [String:Any] = ["application":"Still","system":ProcessInfo.processInfo.operatingSystemVersionString,"checks":checks,"metrics":metrics,"failures":failures,"actualDMMGamesTested":false]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:output.appendingPathComponent("test-report.json")); print(String(data:data,encoding:.utf8) ?? "")
        }
        fflush(stdout); app.quitting = true; exit(failures == 0 ? 0 : 1)
    }
}
