import Foundation

public enum RunMode: String, Codable, CaseIterable, Sendable {
    case continuous, eco
    public var title: String { self == .continuous ? "常速" : "节能" }
}
public enum Address {
    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\r") else { return nil }
        if text == "about:blank" { return URL(string: text) }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil,
           !text.hasPrefix("localhost:"), text.range(of: #"^[^/ ]+\.[^/ ]+:\d"#, options: .regularExpression) == nil {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return url
        }
        let hostLike = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[::1]"))
        if hostLike {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")
            if let url = URL(string: (local ? "http://" : "https://") + text), url.host != nil,
               url.user == nil, url.password == nil { return url }
            return nil
        }
        var query = URLComponents(string: "https://duckduckgo.com/")!
        query.queryItems = [URLQueryItem(name: "q", value: text)]
        return query.url
    }
    public static func isDMM(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return ["dmm.com", "dmm.co.jp", "dmmgames.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    // Deliberately exclude query strings and fragments from diagnostic exports.
    public static func pageKey(_ url: URL?) -> String {
        guard let url, let host = url.host else { return "" }
        return host.lowercased() + url.path
    }
    public static func originKey(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme) else { return "" }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}
public struct TabRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var mode: RunMode
    public var muted: Bool
    public var autoFocus: Bool
    public var compatibility: Bool
    public var forceFrames: Bool
    public var pinned: Bool
    public var sleeping: Bool
    public init(id: UUID = UUID(), url: String = "about:blank", title: String = "新标签页", mode: RunMode = .eco,
                muted: Bool = false, autoFocus: Bool = false, compatibility: Bool = false,
                forceFrames: Bool = false, pinned: Bool = false, sleeping: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.mode = mode; self.muted = muted
        self.autoFocus = autoFocus; self.compatibility = compatibility; self.forceFrames = forceFrames
        self.pinned = pinned; self.sleeping = sleeping
    }
}
public struct Visit: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var url: String
    public var date: Date = Date()
    public init(title: String, url: String) { self.title = title; self.url = url }
}
public struct WindowRecord: Codable, Sendable {
    public var tabs: [TabRecord]
    public var selected: UUID?
    public init(tabs: [TabRecord], selected: UUID?) { self.tabs = tabs; self.selected = selected }
}
public struct SessionRecord: Codable, Sendable {
    public var version = 1
    public var windows: [WindowRecord]
    public init(windows: [WindowRecord]) { self.windows = windows }
}
public struct PageRule: Codable, Sendable {
    public var mode: RunMode
    public var autoFocus: Bool
    public var compatibility: Bool
    public var forceFrames: Bool
    public init(mode: RunMode, autoFocus: Bool, compatibility: Bool, forceFrames: Bool) {
        self.mode = mode; self.autoFocus = autoFocus; self.compatibility = compatibility; self.forceFrames = forceFrames
    }
}
public struct ProbeSample: Sendable {
    public var elapsed: Double
    public var ticks: Int
    public var frames: Int
    public var largestGap: Double
    public var ticksPerSecond: Double { elapsed > 0 ? Double(ticks) / elapsed : 0 }
    public var framesPerSecond: Double { elapsed > 0 ? Double(frames) / elapsed : 0 }
    public var stalled: Bool { largestGap > 3 || (elapsed > 10 && ticksPerSecond < 5) }
    public init(elapsed: Double, ticks: Int, frames: Int, largestGap: Double) {
        self.elapsed = max(0, elapsed); self.ticks = max(0, ticks); self.frames = max(0, frames); self.largestGap = max(0, largestGap)
    }
}
public enum TabOrder {
    public static func moving<T: Identifiable>(_ items: [T], id: T.ID, before target: T.ID) -> [T] {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to - (from < to ? 1 : 0))
        return result
    }
}
