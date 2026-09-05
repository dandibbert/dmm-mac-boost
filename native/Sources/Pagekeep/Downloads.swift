import AppKit
import Combine
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name = "准备下载"
    @Published var fraction = 0.0
    @Published var state = "等待保存位置"
    @Published var destination: URL?
    @Published var finished = false
    @Published var download: WKDownload?
    var observation: NSKeyValueObservation?
    weak var window: NSWindow?
    init(download: WKDownload, window: NSWindow?) { self.download = download; self.window = window }
    func cancel() { download?.cancel { _ in }; download = nil; observation = nil; state = "已取消" }
}
@MainActor
final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadCenter()
    @Published var items: [DownloadItem] = []
    func item(_ download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }
    func add(_ download: WKDownload, window: NSWindow?) {
        let value = DownloadItem(download: download, window: window); items.insert(value, at: 0)
        download.delegate = self
        value.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak value] progress, _ in
            DispatchQueue.main.async { value?.fraction = progress.fractionCompleted }
        }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let value = item(download) else { completionHandler(nil); return }
        value.name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let panel = NSSavePanel(); panel.nameFieldStringValue = value.name; panel.canCreateDirectories = true
        let finished: (NSApplication.ModalResponse) -> Void = { answer in
            guard answer == .OK, let url = panel.url else {
                value.state = "已取消"; value.observation = nil; value.download = nil; completionHandler(nil); return
            }
            value.destination = url; value.state = "正在下载"; completionHandler(url)
        }
        if let window = value.window { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { finished(panel.runModal()) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let value = item(download) else { return }
        value.fraction = 1; value.finished = true; value.state = "已完成"; value.observation = nil; value.download = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let value = item(download) else { return }
        value.state = "下载失败：\(error.localizedDescription)"; value.observation = nil; value.download = nil
    }
}
