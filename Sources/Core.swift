import Foundation

enum RunMode: String, Codable { case steady, economy }
struct GamePreferences: Codable, Equatable {
    var mode: RunMode = .economy
    var mute = false
    var autoFocus = false
    var frameCompatibility = false
    var visibilityCompatibility = false
    var allowPopups = false
    var zoom = 1.0
    var focusSelector: String? = nil
}
struct TabRecord: Codable {
    var id = UUID()
    var url: String = ""
    var title: String = "新标签页"
    var pinned = false
    var sleeping = false
    var preferences = GamePreferences()
}
struct WindowRecord: Codable {
    var id = UUID()
    var tabs: [TabRecord] = []
    var selected: UUID? = nil
}
struct SavedPage: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
}
struct Settings: Codable {
    var restoreSession = true
    var preventIdleSleep = false
    var defaultGameFocus = true
    var confirmQuit = true
    var searchEngine = "https://www.google.com/search"
}
struct PersistentState: Codable {
    var version = 1
    var windows: [WindowRecord] = []
    var bookmarks: [SavedPage] = []
    var history: [SavedPage] = []
    var games: [String: GamePreferences] = [:]
    var settings = Settings()
}
enum Address {
    static func resolve(_ text: String, searchEngine: String = "https://www.google.com/search") -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input == "about:blank" { return URL(string: input) }
        let lower = input.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let url = URL(string: input), url.host != nil else { return nil }
            return url
        }
        let noWhitespace = !input.contains(where: { $0.isWhitespace })
        let local = lower.hasPrefix("localhost") || lower.hasPrefix("127.") || lower.hasPrefix("[::1]")
        if noWhitespace && (local || input.contains(".")) && !input.contains("://") {
            let first = input.components(separatedBy: "/")[0]
            if let colon = first.firstIndex(of: ":"), !first.hasPrefix("[") {
                let suffix = first[first.index(after: colon)...]
                guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
            }
            return URL(string: (local ? "http://" : "https://") + input)
        }
        if noWhitespace && input.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        var parts = URLComponents(string: searchEngine)
        parts?.queryItems = [URLQueryItem(name: "q", value: input)]
        return parts?.url
    }
    static func gameKey(_ url: URL?) -> String? {
        guard let url, let host = url.host, let scheme = url.scheme, ["https", "http"].contains(scheme) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)\(url.path)"
    }
    static func isDMM(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return ["dmm.com", "dmm.co.jp"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func isGame(_ url: URL?) -> Bool {
        guard isDMM(url), let url else { return false }
        return url.host == "play.games.dmm.com" || url.path.contains("/gadgets/") || url.path.contains("/game/")
    }
    static func redacted(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "新标签页" }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string ?? ""
    }
}
func jsonString<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}
@MainActor final class BrowserStore {
    static var shared = BrowserStore()
    var state = PersistentState()
    let directory: URL
    var loadError: String?
    private var pendingSave: DispatchWorkItem?
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let file = self.directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: file))
            }
        } catch { loadError = error.localizedDescription }
    }
    func preferences(for url: URL?) -> GamePreferences {
        if let key = Address.gameKey(url), let saved = state.games[key] { return saved }
        var preferences = GamePreferences()
        if Address.isGame(url) {
            preferences.mode = .steady
            preferences.autoFocus = state.settings.defaultGameFocus
            preferences.frameCompatibility = true
            preferences.visibilityCompatibility = true
        }
        return preferences
    }
    func savePreferences(_ preferences: GamePreferences, for url: URL?) {
        if let key = Address.gameKey(url) { state.games[key] = preferences; scheduleSave() }
    }
    func visit(title: String, url: URL?) {
        guard let url, ["https", "http"].contains(url.scheme ?? "") else { return }
        state.history.removeAll { $0.url == url.absoluteString }
        state.history.insert(SavedPage(title: title, url: url.absoluteString), at: 0)
        state.history = Array(state.history.prefix(2000)); scheduleSave()
    }
    func toggleBookmark(title: String, url: URL?) {
        guard let url else { return }
        if state.bookmarks.contains(where: { $0.url == url.absoluteString }) {
            state.bookmarks.removeAll { $0.url == url.absoluteString }
        } else { state.bookmarks.append(SavedPage(title: title, url: url.absoluteString)) }
        scheduleSave()
    }
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard loadError == nil else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch { loadError = error.localizedDescription }
    }
    func recoverStorage() {
        let file = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = directory.appendingPathComponent("state-backup-\(Int(Date().timeIntervalSince1970)).json")
            do { try FileManager.default.moveItem(at: file, to: backup) } catch { return }
        }
        loadError = nil; flush()
    }
}
