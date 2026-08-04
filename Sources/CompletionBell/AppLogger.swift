import Foundation

final class AppLogger {
    static let shared = AppLogger()
    private let queue = DispatchQueue(label: "completion-bell.logger")
    let logURL: URL

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CompletionBell", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("app.jsonl")
    }

    func write(_ event: String, fields: [String: Any] = [:]) {
        queue.async {
            var payload = fields
            payload["event"] = event
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let encoded = line.data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: self.logURL.path) {
                FileManager.default.createFile(atPath: self.logURL.path, contents: encoded)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: self.logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: encoded)
            } catch {
                return
            }
        }
    }
}
