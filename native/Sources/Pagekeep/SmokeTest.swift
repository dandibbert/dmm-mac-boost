import AppKit
import WebKit
import BrowserCore
import WebKitBridge

@MainActor enum SmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    static func waitForFixture(_ web: WKWebView) async throws {
        for _ in 0..<60 {
            try await pause(0.2)
            if (try? await web.evaluateJavaScript("Boolean(window.fixtureReady && document.getElementById('game-frame').contentWindow.fixtureToken)")) as? Bool == true { return }
        }
        throw Failure(description: "Fixture failed to load")
    }
    static func gameFrames(_ web: WKWebView) async throws -> Double {
        let value = try await web.evaluateJavaScript("Number(document.getElementById('game-frame').contentWindow.fixtureFrameCount)")
        guard let number = value as? NSNumber else { throw Failure(description: "Game frame counter missing") }
        return number.doubleValue
    }
    static func measure(_ tabs: [BrowserTab], duration: Double = 6.5) async throws -> [[String: Any]] {
        var starts: [Double] = []
        for tab in tabs {
            tab.setProbe(false); tab.setProbe(true)
            guard let web = tab.webView else { throw Failure(description: "Game lost its web view") }
            starts.append(try await gameFrames(web))
        }
        let began = Date()
        try await pause(duration)
        let elapsed = Date().timeIntervalSince(began)
        var reports: [[String: Any]] = []
        for (index, tab) in tabs.enumerated() {
            guard let web = tab.webView else { throw Failure(description: "Game was unloaded while running") }
            let end = try await gameFrames(web)
            reports.append(["gameFramesPerSecond": (end-starts[index])/elapsed, "elapsedSeconds": elapsed,
                            "nativeProbes": measurements(tab), "frameCount": tab.samples.count])
        }
        return reports
    }
    static func run(browser: BrowserWindow) {
        Task { @MainActor in
            var checks: [String: Any] = ["actualGamesVerified": false, "version": "0.2.1"]
            do {
                guard let tab = browser.model.active else { throw Failure(description: "Initial tab missing") }
                let fixtureURL = URL(string: "http://127.0.0.1:18765/Diagnostics.html?smoke=1")!
                tab.navigate(fixtureURL)
                guard let web = tab.webView else { throw Failure(description: "Web view missing") }
                NSApp.activate(ignoringOtherApps: true)
                try await waitForFixture(web)
                browser.window?.makeFirstResponder(web)
                let isolated = try await web.evaluateJavaScript("typeof globalThis.__pagekeepConfigure === 'function'", in: nil, in: .defaultClient)
                try require(isolated as? Bool == true, "Isolated runtime missing")
                let privateHelper = try await web.evaluateJavaScript("typeof window.__pagekeepConfigure === 'undefined'")
                try require(privateHelper as? Bool == true, "App helper leaked into the page world")
                checks["isolatedWorld"] = true
                let originalRAF = try await web.evaluateJavaScript("String(requestAnimationFrame).includes('[native code]')")
                try require(originalRAF as? Bool == true, "Page animation API was modified")
                checks["pageAPIsUnmodified"] = true
                let token = try await web.evaluateJavaScript("window.fixtureToken") as? String
                tab.setMode(.continuous)
                for _ in 0..<100 { tab.setMode(.eco); tab.setMode(.continuous) }
                try await pause(0.5)
                let after = try await web.evaluateJavaScript("window.fixtureToken") as? String
                try require(tab.webView === web && token == after, "Hot switching reloaded the page")
                checks["hotSwitchesWithoutReload"] = 200
                _ = try await web.evaluateJavaScript("window.savedGameNode=document.getElementById('game-frame');window.savedGameWindow=savedGameNode.contentWindow;window.savedGameToken=savedGameWindow.fixtureToken;true;")
                try await snapshot(web, name: "page-normal.png")
                tab.focus("on")
                for _ in 0..<30 { if tab.focused { break }; try await pause(0.1) }
                try require(tab.focused, "Native game focus did not find the fixture")
                try await pause(0.5)
                capture(browser, name: "browser-focused-chrome.png")
                if let region = NativeFocus.shared.regions[ObjectIdentifier(web)] { try await snapshot(web, name: "game-focused.png", rect: region.rect) }
                tab.focus("off"); try await pause(0.3)
                let preserved = try await web.evaluateJavaScript("savedGameNode===document.getElementById('game-frame') && savedGameWindow===savedGameNode.contentWindow && savedGameToken===savedGameWindow.fixtureToken")
                try require(preserved as? Bool == true, "Focus replaced or reloaded the game frame")
                checks["focusPreservesIframeAndSession"] = true
                try require(PKMute(web, true) && PKAudioMuted(web)?.boolValue == true, "Native page mute unavailable")
                try require(PKMute(web, false), "Unmute failed")
                checks["nativePageMute"] = true
                try require(PKInspector(web, "show"), "Web Inspector unavailable")
                try await pause(0.5); _ = PKInspector(web, "close")
                checks["nativeInspector"] = true
                try await pause(0.5)
                let foreground = try await measure([tab])
                checks["foreground"] = foreground
                try require(tab.samples.count >= 3, "Missing main, same-origin or visible cross-origin measurements")
                guard let baseline = foreground.first?["gameFramesPerSecond"] as? Double else { throw Failure(description: "Baseline missing") }
                try require(baseline > 20, "CI cannot establish a usable foreground animation baseline")

                let second = browser.model.newTab(fixtureURL)
                guard let secondWeb = second.webView else { throw Failure(description: "Second game missing") }
                try await waitForFixture(secondWeb); second.setMode(.continuous)
                let third = browser.model.newTab(fixtureURL)
                guard let thirdWeb = third.webView else { throw Failure(description: "Third game missing") }
                try await waitForFixture(thirdWeb); third.setMode(.continuous)
                let other = browser.model.newTab()
                try await pause(0.7)
                let background = try await measure([tab, second, third])
                checks["threeBackgroundGames"] = background
                try require(tab.webView === web, "Changing tabs destroyed the web view")
                let originalToken = try await web.evaluateJavaScript("window.fixtureToken") as? String
                tab.setMode(.eco); try await pause(0.8)
                let released = web.window == nil
                tab.setMode(.continuous); try await pause(0.8)
                checks["backgroundEnergySwitch"] = ["releasedRenderingSurface": released, "resumedRenderingSurface": web.window != nil]
                try require(released && web.window != nil, "Eco/continuous switch did not release/reacquire native rendering")
                let energyToken = try await web.evaluateJavaScript("window.fixtureToken") as? String
                try require(originalToken == energyToken, "Energy switch reloaded a background game")
                browser.model.select(tab)
                browser.model.close(second, confirmed: true); browser.model.close(third, confirmed: true); browser.model.close(other, confirmed: true)
                try await pause(0.5)
                browser.window?.miniaturize(nil); try await pause(0.5)
                let minimized = try await measure([tab])
                checks["minimizedWindow"] = minimized
                browser.window?.deminiaturize(nil); try await pause(0.5)
                NSApp.hide(nil); try await pause(0.5)
                let hidden = try await measure([tab])
                checks["hiddenApplication"] = hidden
                NSApp.unhide(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await pause(0.5)
                let cover = NSWindow(contentRect: browser.window!.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                cover.isReleasedWhenClosed = false; cover.backgroundColor = .windowBackgroundColor; cover.orderFrontRegardless()
                try await pause(0.5)
                let occluded = try await measure([tab])
                checks["occludedWindow"] = occluded
                cover.orderOut(nil); cover.close()
                checks["unavailableNativeControls"] = tab.unavailable
                let rates = (background + minimized + hidden + occluded).compactMap { $0["gameFramesPerSecond"] as? Double }
                let minimumRatio = (rates.min() ?? 0) / baseline
                checks["syntheticMinimumBackgroundRatio"] = minimumRatio
                checks["syntheticTolerance"] = 0.90
                checks["syntheticBackgroundSpeedPassed"] = minimumRatio >= 0.90
                checks["backgroundFullSpeedVerifiedForActualGames"] = false
                checks["nativeSnapshotsProduced"] = true
                checks["result"] = "functional-tests-passed"
                tab.setProbe(false); tab.notice = nil
                browser.window?.makeFirstResponder(web)
                capture(browser, name: "browser-normal-chrome.png")
                try await snapshot(web, name: "page-final.png")
                write(checks)
                try require(minimumRatio >= 0.90, "Background synthetic game throughput fell below 90% of its foreground baseline")
                print("PAGEKEEP_SMOKE_PASS")
                browser.model.tabs.forEach { $0.dispose() }; exit(0)
            } catch {
                checks["result"] = "failed"; checks["error"] = String(describing: error)
                capture(browser, name: "browser-failure.png"); write(checks)
                fputs("PAGEKEEP_SMOKE_FAIL: \(error)\n", stderr); exit(1)
            }
        }
    }
    static func measurements(_ tab: BrowserTab) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in tab.samples {
            output[key] = ["timerHz": value.0.ticksPerSecond, "rafHz": value.0.framesPerSecond,
                           "maxGapSeconds": value.0.largestGap, "elapsedSeconds": value.0.elapsed,
                           "reportAgeSeconds": Date().timeIntervalSince(value.1), "realHidden": value.2] as [String: Any]
        }
        return output
    }
    static func outputURL(_ name: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAGEKEEP_TEST_OUTPUT"] ?? FileManager.default.currentDirectoryPath).appendingPathComponent(name)
    }
    static func snapshot(_ web: WKWebView, name: String, rect: CGRect? = nil) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect ?? web.bounds
        configuration.afterScreenUpdates = true
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: Failure(description: "WebKit snapshot returned no image")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "WebKit snapshot could not be encoded") }
        try png.write(to: outputURL(name))
    }
    static func capture(_ browser: BrowserWindow, name: String) {
        // AppKit's cache captures chrome only; remote web layers are captured separately using takeSnapshot.
        guard let view = browser.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: outputURL(name)) }
    }
    static func write(_ checks: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: outputURL("smoke-results.json")) }
    }
}
