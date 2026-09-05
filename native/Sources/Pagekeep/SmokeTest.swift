import AppKit
import WebKit
import BrowserCore
import WebKitBridge

@MainActor enum SmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    static func run(browser: BrowserWindow) {
        Task { @MainActor in
            var checks: [String: Any] = ["actualGamesVerified": false, "version": "0.2.1"]
            do {
                guard let tab = browser.model.active else { throw Failure(description: "Initial tab missing") }
                tab.navigate(URL(string: "http://127.0.0.1:18765/Diagnostics.html?smoke=1")!)
                guard let web = tab.webView else { throw Failure(description: "Web view missing") }
                NSApp.activate(ignoringOtherApps: true)
                var loaded = false
                for _ in 0..<40 {
                    try await pause(0.25)
                    if (try? await web.evaluateJavaScript("Boolean(window.fixtureReady && document.getElementById('game-frame').contentWindow.fixtureToken)")) as? Bool == true { loaded = true; break }
                }
                try require(loaded, "Fixture failed to load")
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
                tab.focus("on")
                for _ in 0..<30 { if tab.focused { break }; try await pause(0.1) }
                try require(tab.focused, "Native game focus did not find the fixture")
                try await pause(0.5)
                capture(browser, name: "browser-focused.png")
                tab.focus("off"); try await pause(0.3)
                let preserved = try await web.evaluateJavaScript("savedGameNode===document.getElementById('game-frame') && savedGameWindow===savedGameNode.contentWindow && savedGameToken===savedGameWindow.fixtureToken")
                try require(preserved as? Bool == true, "Focus replaced or reloaded the game frame")
                checks["focusPreservesIframeAndSession"] = true
                let muted = PKMute(web, true)
                try require(muted && PKAudioMuted(web)?.boolValue == true, "Native page mute unavailable")
                try require(PKMute(web, false), "Unmute failed")
                checks["nativePageMute"] = true
                let inspector = PKInspector(web, "show")
                try require(inspector, "Web Inspector unavailable")
                try await pause(0.5); _ = PKInspector(web, "close")
                checks["nativeInspector"] = true
                tab.setProbe(true); try await pause(3)
                try require(tab.samples.count >= 3, "Missing main, same-origin or cross-origin frame measurements")
                checks["measuredFrameCount"] = tab.samples.count
                checks["foreground"] = measurements(tab)
                tab.setProbe(false); tab.setProbe(true)
                let other = browser.model.newTab()
                try await pause(5)
                browser.model.select(tab); try await pause(0.2)
                checks["backgroundTab"] = measurements(tab)
                try require(tab.webView === web, "Changing tabs destroyed the web view")
                browser.model.close(other, confirmed: true)
                tab.setProbe(false); tab.setProbe(true)
                browser.window?.miniaturize(nil); try await pause(5)
                browser.window?.deminiaturize(nil); try await pause(0.4)
                checks["minimizedWindow"] = measurements(tab)
                checks["unavailableNativeControls"] = tab.unavailable
                // Functional smoke tests are not a claim of foreground-equivalent game speed.
                checks["backgroundFullSpeedVerified"] = false
                checks["result"] = "functional-tests-passed"
                tab.setProbe(false)
                capture(browser, name: "browser-normal.png")
                write(checks); print("PAGEKEEP_SMOKE_PASS")
                browser.model.tabs.forEach { $0.dispose() }
                exit(0)
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
    static func capture(_ browser: BrowserWindow, name: String) {
        guard let view = browser.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: outputURL(name)) }
    }
    static func write(_ checks: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: outputURL("smoke-results.json")) }
    }
}
