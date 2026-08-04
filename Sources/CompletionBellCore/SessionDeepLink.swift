import Foundation

public enum SessionDeepLink {
    public static func url(for session: SessionSnapshot) -> URL? {
        var components = URLComponents()
        switch session.tool {
        case .codex:
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/\(session.sessionID)"
        case .claudeCode:
            // The desktop app registers no focus-existing-session route; its
            // only per-session route is claude://resume, whose semantics FORK
            // the transcript into a duplicate conversation. Activating the
            // app is the honest behavior until a stable route exists.
            return nil
        case .craft:
            return nil
        case .newMax:
            guard !session.sessionID.hasPrefix("hermes:") else { return nil }
            components.scheme = "newmax"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "conversation", value: session.sessionID)]
        case .workBuddy:
            guard !session.sessionID.hasPrefix("automation:") else { return nil }
            components.scheme = "workbuddy"
            components.host = "chat"
            components.path = "/\(session.sessionID)"
        }
        return components.url
    }

    /// Deliberately unrouted: claude://resume IMPORTS the transcript into a
    /// brand-new desktop conversation (fork), so row clicks never use this.
    /// The format matches the CLI's own desktop handoff — cwd included so the
    /// app resolves the project directory — kept ready for a future explicit
    /// "open a forked copy" affordance.
    public static func claudeResumeForkURL(for session: SessionSnapshot) -> URL? {
        guard session.tool == .claudeCode,
              let cwd = session.projectPath, !cwd.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [
            URLQueryItem(name: "session", value: session.sessionID),
            URLQueryItem(name: "cwd", value: cwd),
        ]
        return components.url
    }
}
