import Foundation

public enum QuotaProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

public enum QuotaWindowKind: String, Codable, Sendable {
    case session
    case weekly
    case monthly
    case model
    case credits
    case other
}

public struct QuotaWindowSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: QuotaProvider
    public let kind: QuotaWindowKind
    public let labelChinese: String
    public let labelEnglish: String
    public let remainingPercent: Double
    public let resetAt: Date?
    public let windowMinutes: Int?

    public init(
        id: String,
        provider: QuotaProvider,
        kind: QuotaWindowKind,
        labelChinese: String,
        labelEnglish: String,
        remainingPercent: Double,
        resetAt: Date? = nil,
        windowMinutes: Int? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.labelChinese = labelChinese
        self.labelEnglish = labelEnglish
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetAt = resetAt
        self.windowMinutes = windowMinutes
    }

    public var usedPercent: Double { 100 - remainingPercent }
}

public enum QuotaProviderAvailability: String, Codable, Sendable {
    case ready
    case signedOut
    case unavailable
    case failed
}

public struct QuotaProviderSnapshot: Identifiable, Equatable, Sendable {
    public let provider: QuotaProvider
    public let availability: QuotaProviderAvailability
    public let windows: [QuotaWindowSnapshot]
    public let messageChinese: String?
    public let messageEnglish: String?
    public let updatedAt: Date

    public var id: String { provider.rawValue }

    public init(
        provider: QuotaProvider,
        availability: QuotaProviderAvailability,
        windows: [QuotaWindowSnapshot] = [],
        messageChinese: String? = nil,
        messageEnglish: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.provider = provider
        self.availability = availability
        self.windows = windows
        self.messageChinese = messageChinese
        self.messageEnglish = messageEnglish
        self.updatedAt = updatedAt
    }
}

public extension QuotaProviderSnapshot {
    /// The single window worth showing where only one number fits (notch strip,
    /// capsule, edge tag): Codex is judged by its weekly budget, Claude by the
    /// five-hour session window. Falls back to the most constrained window when
    /// the canonical one is missing, so the readout never goes blank.
    var compactWindow: QuotaWindowSnapshot? {
        let preferred: QuotaWindowKind = provider == .codex ? .weekly : .session
        return windows.first { $0.kind == preferred }
            ?? windows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

public enum QuotaParser {
    public static func codex(from result: [String: Any], now: Date = Date()) -> QuotaProviderSnapshot {
        let selected: [String: Any]
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            selected = codex
        } else if let direct = result["rateLimits"] as? [String: Any] {
            selected = direct
        } else {
            selected = result
        }

        var windows: [QuotaWindowSnapshot] = []
        for key in ["primary", "secondary"] {
            guard let value = selected[key] as? [String: Any],
                  let used = number(value["usedPercent"]) else { continue }
            let duration = integer(value["windowDurationMins"])
            let kind = codexKind(key: key, minutes: duration)
            let labels = labels(for: kind)
            windows.append(QuotaWindowSnapshot(
                id: "codex:\(key)",
                provider: .codex,
                kind: kind,
                labelChinese: labels.zh,
                labelEnglish: labels.en,
                remainingPercent: 100 - used,
                resetAt: date(value["resetsAt"]),
                windowMinutes: duration
            ))
        }

        return QuotaProviderSnapshot(
            provider: .codex,
            availability: windows.isEmpty ? .unavailable : .ready,
            windows: windows,
            messageChinese: windows.isEmpty ? "Codex 暂未返回额度" : nil,
            messageEnglish: windows.isEmpty ? "Codex did not return quota data" : nil,
            updatedAt: now
        )
    }

    public static func claude(from result: [String: Any], now: Date = Date()) -> QuotaProviderSnapshot {
        var windows: [QuotaWindowSnapshot] = []
        var seenIDs = Set<String>()

        for (key, rawValue) in result.sorted(by: { $0.key < $1.key }) {
            guard let value = rawValue as? [String: Any],
                  let utilization = number(value["utilization"]) else { continue }
            let id = "claude:\(key)"
            let kind = claudeKind(for: key)
            let labels = claudeLabels(for: key, kind: kind)
            seenIDs.insert(id)
            windows.append(QuotaWindowSnapshot(
                id: id,
                provider: .claude,
                kind: kind,
                labelChinese: labels.zh,
                labelEnglish: labels.en,
                remainingPercent: 100 - utilization,
                resetAt: date(value["resets_at"])
            ))
        }

        // Anthropic can add model-scoped windows without adding a new top-level
        // field. Surface those dynamically, while keeping top-level values as
        // the higher-authority source when both forms exist.
        if let limits = result["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      !name.isEmpty,
                      let percent = number(limit["percent"]) else { continue }
                let group = (limit["group"] as? String) ?? "model"
                let slug = stableSlug("\(group)-\(name)")
                let id = "claude:model:\(slug)"
                guard !seenIDs.contains(id) else { continue }
                windows.append(QuotaWindowSnapshot(
                    id: id,
                    provider: .claude,
                    kind: .model,
                    labelChinese: name,
                    labelEnglish: name,
                    remainingPercent: 100 - percent,
                    resetAt: date(limit["resets_at"])
                ))
            }
        }

        windows.sort { quotaRank($0.kind) < quotaRank($1.kind) }
        return QuotaProviderSnapshot(
            provider: .claude,
            availability: windows.isEmpty ? .unavailable : .ready,
            windows: windows,
            messageChinese: windows.isEmpty ? "Claude 暂未返回额度" : nil,
            messageEnglish: windows.isEmpty ? "Claude did not return quota data" : nil,
            updatedAt: now
        )
    }

    /// Parses the quota summary printed by Claude Code's built-in `/usage`
    /// command. This is a fallback for installations where Claude keeps its
    /// active login outside the legacy `.credentials.json` access token.
    public static func claudeUsageText(_ text: String, now: Date = Date()) -> QuotaProviderSnapshot {
        var windows: [QuotaWindowSnapshot] = []
        // Recent Claude Code builds append reset details after `used`, while
        // older builds end the line there. Accept both without hard-coding a
        // particular reset-time locale or subscription window.
        let pattern = #"^Current\s+(.+?):\s*([0-9]+(?:\.[0-9]+)?)%\s+used(?:\s+.*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return QuotaProviderSnapshot(
                provider: .claude,
                availability: .failed,
                messageChinese: "Claude 额度暂时读不到",
                messageEnglish: "Claude quota is temporarily unavailable",
                updatedAt: now
            )
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = expression.firstMatch(in: trimmed, range: range),
                  let labelRange = Range(match.range(at: 1), in: trimmed),
                  let percentRange = Range(match.range(at: 2), in: trimmed),
                  let used = Double(trimmed[percentRange]) else { continue }

            let rawLabel = String(trimmed[labelRange])
            let normalized = rawLabel.lowercased()
            let kind: QuotaWindowKind
            let labelChinese: String
            let labelEnglish: String

            if normalized == "session" {
                kind = .session
                labelChinese = "本轮"
                labelEnglish = "Session"
            } else if normalized.hasPrefix("week") {
                let scope = parenthesizedValue(in: rawLabel)
                if scope?.lowercased() == "all models" || scope == nil {
                    kind = .weekly
                    labelChinese = "本周"
                    labelEnglish = "Weekly"
                } else if let scope {
                    kind = .model
                    labelChinese = "周 · \(scope)"
                    labelEnglish = "Week · \(scope)"
                } else {
                    kind = .weekly
                    labelChinese = "本周"
                    labelEnglish = "Weekly"
                }
            } else if normalized.hasPrefix("month") {
                kind = .monthly
                labelChinese = "本月"
                labelEnglish = "Monthly"
            } else {
                kind = .other
                labelChinese = rawLabel
                labelEnglish = rawLabel
            }

            let slug = stableSlug(rawLabel)
            windows.append(QuotaWindowSnapshot(
                id: "claude:cli:\(slug)",
                provider: .claude,
                kind: kind,
                labelChinese: labelChinese,
                labelEnglish: labelEnglish,
                remainingPercent: 100 - used
            ))
        }

        windows.sort { quotaRank($0.kind) < quotaRank($1.kind) }
        return QuotaProviderSnapshot(
            provider: .claude,
            availability: windows.isEmpty ? .unavailable : .ready,
            windows: windows,
            messageChinese: windows.isEmpty ? "Claude 暂未返回额度" : nil,
            messageEnglish: windows.isEmpty ? "Claude did not return quota data" : nil,
            updatedAt: now
        )
    }

    private static func codexKind(key: String, minutes: Int?) -> QuotaWindowKind {
        guard let minutes else { return key == "secondary" ? .weekly : .other }
        if minutes >= 28 * 24 * 60 { return .monthly }
        if minutes >= 6 * 24 * 60 { return .weekly }
        if minutes <= 6 * 60 { return .session }
        return key == "secondary" ? .weekly : .other
    }

    private static func claudeKind(for key: String) -> QuotaWindowKind {
        let value = key.lowercased()
        if value.contains("five_hour") || value.contains("session") { return .session }
        if value.contains("seven_day") || value.contains("week") { return value == "seven_day" ? .weekly : .model }
        if value.contains("month") { return .monthly }
        if value.contains("extra") || value.contains("credit") { return .credits }
        return .other
    }

    private static func labels(for kind: QuotaWindowKind) -> (zh: String, en: String) {
        switch kind {
        case .session: return ("本轮", "Session")
        case .weekly: return ("本周", "Weekly")
        case .monthly: return ("本月", "Monthly")
        case .model: return ("模型", "Model")
        case .credits: return ("余额", "Credits")
        case .other: return ("额度", "Quota")
        }
    }

    private static func claudeLabels(for key: String, kind: QuotaWindowKind) -> (zh: String, en: String) {
        let normalized = key.lowercased()
        if normalized == "five_hour" { return ("本轮", "Session") }
        if normalized == "seven_day" { return ("本周", "Weekly") }
        if normalized.hasPrefix("seven_day_") {
            let name = displayName(String(normalized.dropFirst("seven_day_".count)))
            return ("周 · \(name)", "Week · \(name)")
        }
        if normalized.contains("extra_usage") { return ("额外用量", "Extra usage") }
        let fallback = labels(for: kind)
        return fallback
    }

    private static func displayName(_ value: String) -> String {
        value.split(separator: "_").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    private static func parenthesizedValue(in value: String) -> String? {
        guard let opening = value.firstIndex(of: "("),
              let closing = value[opening...].firstIndex(of: ")"),
              opening < closing else { return nil }
        let content = value[value.index(after: opening)..<closing]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private static func quotaRank(_ kind: QuotaWindowKind) -> Int {
        switch kind {
        case .session: return 0
        case .weekly: return 1
        case .model: return 2
        case .monthly: return 3
        case .credits: return 4
        case .other: return 5
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        return Int(number)
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func stableSlug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let raw = value.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return raw.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}

/// Coarse remaining-quota bands for the compact edge tag. Colour alone cannot
/// convey an exact figure — it answers "how tight is this?" while the number
/// printed inside the gem carries the precision.
public enum QuotaTier: String, CaseIterable, Sendable {
    case full
    case good
    case low
    case critical

    public static func tier(forRemainingPercent percent: Double) -> QuotaTier {
        let clamped = min(100, max(0, percent))
        if clamped >= 70 { return .full }
        if clamped >= 35 { return .good }
        if clamped >= 15 { return .low }
        return .critical
    }
}
