import Foundation

/// Local record of a word the user backspaced and retyped. Nothing here is
/// sent off the machine. Password fields never reach `record`: secure input
/// discards the session instead of editing it.
public protocol TypoMemory: AnyObject {
    func record(wrong: String, wrongKeys: String, final: String, finalKeys: String)
    /// The one replacement stored for `wrong`, when every record agrees.
    func uniqueFinal(for wrong: String) -> String?
}

public enum TypoLogPolicy {
    /// Both sides need a couple of letters or jamo. Digits and one-syllable
    /// slips are not kept.
    public static func shouldStore(wrong: String, final: String, wrongKeys: String, finalKeys: String) -> Bool {
        guard wrong != final else { return false }
        guard wrong.count <= 80, final.count <= 80 else { return false }
        guard wrongKeys.count <= 80, finalKeys.count <= 80 else { return false }
        guard !wrong.contains(where: \.isNewline), !final.contains(where: \.isNewline) else { return false }
        return significantCount(wrong) >= 2 && significantCount(final) >= 2
    }

    private static func significantCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            let value = scalar.value
            let hangul = (0xAC00...0xD7A3).contains(value) || (0x3131...0x318E).contains(value)
            if hangul || scalar.properties.isAlphabetic {
                return count + 1
            }
            return count
        }
    }
}

/// Append-only `typos.jsonl` under Application Support. The file is capped
/// and rewritten from the tail when it grows past the cap.
public final class TypoLog: TypoMemory, @unchecked Sendable {
    public static let maxBytes = 256 * 1024

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Sebeol390", isDirectory: true)
            .appendingPathComponent("typos.jsonl")
    }

    private struct Entry: Codable, Equatable {
        var wrong: String
        var wrongKeys: String
        var final: String
        var finalKeys: String
        var at: String
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init() {
        self.fileURL = Self.defaultFileURL
        load()
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public func record(wrong: String, wrongKeys: String, final: String, finalKeys: String) {
        guard TypoLogPolicy.shouldStore(wrong: wrong, final: final, wrongKeys: wrongKeys, finalKeys: finalKeys) else { return }
        let entry = Entry(
            wrong: wrong,
            wrongKeys: wrongKeys,
            final: final,
            finalKeys: finalKeys,
            at: ISO8601DateFormatter().string(from: Date())
        )
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        save()
    }

    public func uniqueFinal(for wrong: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var seen: [String] = []
        for entry in entries where entry.wrong == wrong {
            if !seen.contains(entry.final) {
                seen.append(entry.final)
            }
        }
        return seen.count == 1 ? seen[0] : nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        entries = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let raw = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: raw)
        }
    }

    private func save() {
        while encodedSize(entries) > Self.maxBytes, entries.count > 1 {
            entries.removeFirst()
        }
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry), let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
    }

    private func encodedSize(_ entries: [Entry]) -> Int {
        entries.reduce(0) { total, entry in
            let bytes = (try? encoder.encode(entry))?.count ?? 0
            return total + bytes + 1
        }
    }
}
