import Foundation
import Combine

@MainActor
final class SitePermissions: ObservableObject {
    struct Entry: Codable, Identifiable {
        let id: String
        var label: String
        var granted: Bool
    }
    static let shared = SitePermissions()
    @Published private(set) var entries: [Entry] = []
    private let storageKey = "pagekeep.sitePermissions.v1"
    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }
    func decision(for key: String) -> Bool? { entries.first { $0.id == key }?.granted }
    func save(key: String, label: String, granted: Bool) {
        entries.removeAll { $0.id == key }
        entries.append(Entry(id: key, label: label, granted: granted))
        entries.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        persist()
    }
    func remove(_ key: String) { entries.removeAll { $0.id == key }; persist() }
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
