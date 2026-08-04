import CompletionBellCore
import Foundation

final class QuotaMonitorService {
    struct Update {
        let providers: [QuotaProviderSnapshot]
        let refreshedAt: Date
    }

    var onUpdate: ((Update) -> Void)?

    private let queue = DispatchQueue(label: "jianling.quota-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stopped = true

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.stopped = false
            self.performRefresh()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5 * 60, repeating: 5 * 60, leeway: .seconds(15))
            timer.setEventHandler { [weak self] in self?.performRefresh() }
            self.timer = timer
            timer.resume()
        }
    }

    func refreshNow() {
        queue.async { [weak self] in self?.performRefresh() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func performRefresh() {
        guard !stopped else { return }
        let now = Date()
        let providers = [readCodex(at: now), readClaude(at: now)]
        AppLogger.shared.write("quota_refresh", fields: [
            "providers": providers.count,
            "ready": providers.filter { $0.availability == .ready }.count,
            "windows": providers.reduce(0) { $0 + $1.windows.count },
            "provider_states": Dictionary(uniqueKeysWithValues: providers.map {
                ($0.provider.rawValue, $0.availability.rawValue)
            }),
            "provider_windows": Dictionary(uniqueKeysWithValues: providers.map {
                ($0.provider.rawValue, $0.windows.count)
            })
        ])
        onUpdate?(Update(providers: providers, refreshedAt: now))
    }

    private func readCodex(at now: Date) -> QuotaProviderSnapshot {
        guard let executable = executableURL(
            candidates: [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "~/.npm-global/bin/codex",
                "~/.local/bin/codex"
            ]
        ) else {
            return unavailable(
                .codex,
                availability: .unavailable,
                chinese: "没有找到 Codex",
                english: "Codex was not found",
                at: now
            )
        }

        do {
            let result = try CodexRateLimitProbe(executableURL: executable).read()
            return QuotaParser.codex(from: result, now: now)
        } catch {
            return unavailable(
                .codex,
                availability: .failed,
                chinese: "Codex 额度暂时读不到",
                english: "Codex quota is temporarily unavailable",
                at: now
            )
        }
    }

    private func readClaude(at now: Date) -> QuotaProviderSnapshot {
        let claudeExecutable = executableURL(
            candidates: [
                "~/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "~/.npm-global/bin/claude"
            ]
        )
        func fallback(
            availability: QuotaProviderAvailability,
            chinese: String,
            english: String
        ) -> QuotaProviderSnapshot {
            if let claudeExecutable {
                do {
                    let text = try ClaudeUsageProbe(executableURL: claudeExecutable).read()
                    if !text.isEmpty {
                        let snapshot = QuotaParser.claudeUsageText(text, now: now)
                        if snapshot.availability == .ready { return snapshot }
                    }
                } catch {
                    AppLogger.shared.write("quota_probe_failed", fields: [
                        "provider": QuotaProvider.claude.rawValue,
                        "reason": String(describing: error)
                    ])
                }
            }
            return unavailable(
                .claude,
                availability: availability,
                chinese: chinese,
                english: english,
                at: now
            )
        }

        let configDirectory: URL
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            configDirectory = URL(fileURLWithPath: configured)
        } else {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        let credentialsURL = configDirectory.appendingPathComponent(".credentials.json")

        guard let data = try? Data(contentsOf: credentialsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return fallback(
                availability: .signedOut,
                chinese: "登录 Claude Code 后会自动显示",
                english: "Sign in to Claude Code to show quota"
            )
        }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           expiresAt / 1_000 < now.timeIntervalSince1970 {
            return fallback(
                availability: .signedOut,
                chinese: "打开 Claude Code 刷新登录后会自动重试",
                english: "Open Claude Code to refresh your sign-in"
            )
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return fallback(availability: .failed, chinese: "Claude 额度暂时读不到", english: "Claude quota is temporarily unavailable")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.207", forHTTPHeaderField: "User-Agent")

        let box = URLResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.store(data: data, response: response, error: error)
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 12) == .success else {
            return fallback(availability: .failed, chinese: "Claude 额度读取超时", english: "Claude quota request timed out")
        }
        let response = box.value
        guard response.error == nil,
              let http = response.response as? HTTPURLResponse else {
            return fallback(availability: .failed, chinese: "Claude 额度暂时读不到", english: "Claude quota is temporarily unavailable")
        }
        if http.statusCode == 401 {
            return fallback(availability: .signedOut, chinese: "打开 Claude Code 刷新登录后会自动重试", english: "Open Claude Code to refresh your sign-in")
        }
        guard (200..<300).contains(http.statusCode),
              let responseData = response.data,
              let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return fallback(availability: .failed, chinese: "Claude 额度暂时读不到", english: "Claude quota is temporarily unavailable")
        }
        let snapshot = QuotaParser.claude(from: result, now: now)
        if snapshot.availability == .ready { return snapshot }
        return fallback(availability: .unavailable, chinese: "Claude 暂未返回额度", english: "Claude did not return quota data")
    }

    private func executableURL(candidates: [String]) -> URL? {
        for candidate in candidates {
            let path = NSString(string: candidate).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func unavailable(
        _ provider: QuotaProvider,
        availability: QuotaProviderAvailability,
        chinese: String,
        english: String,
        at date: Date
    ) -> QuotaProviderSnapshot {
        QuotaProviderSnapshot(
            provider: provider,
            availability: availability,
            messageChinese: chinese,
            messageEnglish: english,
            updatedAt: date
        )
    }
}

private final class ClaudeUsageProbe {
    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func read() throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = quotaProcessEnvironment()
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Claude's subscription endpoint can be noticeably slower while many
        // local agents are active. Keep this off the UI thread and allow one
        // minute before falling back to the quiet unavailable state.
        guard finished.wait(timeout: .now() + 60) == .success else {
            if process.isRunning { process.terminate() }
            throw ProbeError.timeout
        }
        guard process.terminationStatus == 0 else { throw ProbeError.failed(process.terminationStatus) }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["is_error"] as? Bool) != true,
              let result = root["result"] as? String else {
            throw ProbeError.invalidResponse
        }
        return result
    }
}

private final class URLResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Data?, URLResponse?, Error?) = (nil, nil, nil)

    var value: (data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        stored = (data, response, error)
        lock.unlock()
    }
}

private final class CodexRateLimitProbe {
    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func read() throws -> [String: Any] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.environment = quotaProcessEnvironment()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        let response = CodexResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        var buffer = Data()
        let bufferLock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   (object["id"] as? NSNumber)?.intValue == 2,
                   let result = object["result"] as? [String: Any] {
                    response.store(result)
                    semaphore.signal()
                }
            }
            bufferLock.unlock()
        }

        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "jianling", "title": "Jianling", "version": "0.4"]
                ]
            ],
            ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]]
        ]
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }

        guard semaphore.wait(timeout: .now() + 10) == .success,
              let result = response.value else {
            throw ProbeError.timeout
        }
        return result
    }
}

private final class CodexResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?

    var value: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: [String: Any]) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private enum ProbeError: Error {
    case timeout
    case failed(Int32)
    case invalidResponse
}

private func quotaProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let preferredPaths = [
        "\(home)/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(home)/.npm-global/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
    let inheritedPaths = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    var seen = Set<String>()
    environment["PATH"] = (preferredPaths + inheritedPaths)
        .filter { seen.insert($0).inserted }
        .joined(separator: ":")
    return environment
}
