import Foundation

public enum JSONLReader {
    struct IndexedObject {
        let lineIndex: Int
        let object: [String: Any]
    }

    public static func firstObject(at url: URL, maxBytes: Int = 256 * 1024) throws -> [String: Any]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let newline = data.firstIndex(of: 0x0A) else {
            return try decodeObject(data)
        }
        return try decodeObject(data[..<newline])
    }

    public static func tailObjects(
        at url: URL,
        maxBytes: Int = 768 * 1024,
        containingAny markerStrings: [String] = []
    ) throws -> [[String: Any]] {
        try tailIndexedObjects(
            at: url,
            maxBytes: maxBytes,
            containingAny: markerStrings
        ).map(\.object)
    }

    /// Like `tailObjects`, but preserves each candidate's original line index
    /// within the bounded tail. Completion fingerprints historically include
    /// that index, so raw marker filtering must not renumber the records.
    static func tailIndexedObjects(
        at url: URL,
        maxBytes: Int,
        containingAny markerStrings: [String]
    ) throws -> [IndexedObject] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0 && !lines.isEmpty {
            lines.removeFirst()
        }

        let markers = markerStrings.map { Data($0.utf8) }
        return lines.enumerated().compactMap { index, line -> IndexedObject? in
            if !markers.isEmpty && !markers.contains(where: { line.range(of: $0) != nil }) {
                return nil
            }
            do {
                guard let object = try decodeObject(line) else { return nil }
                return IndexedObject(lineIndex: index, object: object)
            } catch {
                return nil
            }
        }
    }

    public static func lastObject(
        at url: URL,
        chunkBytes: Int = 256 * 1024,
        containingAny markerStrings: [String] = [],
        matching predicate: ([String: Any]) -> Bool
    ) throws -> [String: Any]? {
        precondition(chunkBytes > 0)
        // Memory mapping lets us walk backwards without repeatedly copying a
        // giant JSON line across chunk boundaries. Some Codex tool-result
        // records are tens of megabytes, which made the old carry buffer
        // quadratic on cold start.
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let markers = markerStrings.map { Data($0.utf8) }

        var lineEnd = data.endIndex
        if lineEnd > data.startIndex, data[data.index(before: lineEnd)] == 0x0A {
            lineEnd = data.index(before: lineEnd)
        }

        while lineEnd > data.startIndex {
            let searchRange = data.startIndex..<lineEnd
            let newline = data.range(
                of: Data([0x0A]),
                options: [.backwards],
                in: searchRange
            )?.lowerBound
            let lineStart = newline.map { data.index(after: $0) } ?? data.startIndex
            let line = data[lineStart..<lineEnd]

            let couldMatch = markers.isEmpty || markers.contains { line.range(of: $0) != nil }
            if couldMatch, let object = try? decodeObject(line), predicate(object) {
                return object
            }

            guard let newline else { break }
            lineEnd = newline
        }
        return nil
    }

    private static func decodeObject<D: DataProtocol>(_ data: D) throws -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(data))
        return object as? [String: Any]
    }
}

public enum DateParser {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601 = ISO8601DateFormatter()

    public static func parse(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let string = value as? String else { return nil }
        return fractionalISO8601.date(from: string) ?? plainISO8601.date(from: string)
    }
}
