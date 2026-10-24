import Foundation

public final class Lexicon: @unchecked Sendable {
    private let english: [String]
    private let korean: Set<String>
    /// Large Hangul list used only to refuse auto-correction. Not the language lexicon.
    private let validKorean: Set<String>
    private let abbreviations: Set<String>
    private let techStems: Set<String>
    private let indexLock = NSLock()
    private var englishByLength: [Int: [String]]?

    public init(
        english: [String],
        korean: [String],
        abbreviations: [String] = [],
        techStems: [String] = [],
        validKorean: [String] = []
    ) {
        self.english = Array(Set(english.map { $0.lowercased() })).sorted()
        self.korean = Set(korean.map { $0.precomposedStringWithCanonicalMapping })
        self.validKorean = Set(validKorean.map { $0.precomposedStringWithCanonicalMapping })
        self.abbreviations = Set(abbreviations.map { $0.uppercased() })
        self.techStems = Set(techStems.map { $0.lowercased() })
    }

    public func isEnglishWord(_ word: String) -> Bool {
        let key = word.lowercased()
        guard let index = lowerBound(key) else { return false }
        return english[index] == key
    }

    public func isEnglishPrefix(_ prefix: String) -> Bool {
        let key = prefix.lowercased()
        guard !key.isEmpty, let index = lowerBound(key) else { return false }
        return english[index].hasPrefix(key)
    }

    public func isKoreanWord(_ word: String) -> Bool {
        korean.contains(word.precomposedStringWithCanonicalMapping)
    }

    /// True when `word` is in the large validity list. Frequent words live in `isKoreanWord`.
    public func isValidKorean(_ word: String) -> Bool {
        validKorean.contains(word.precomposedStringWithCanonicalMapping)
    }

    public var koreanWordCount: Int { korean.count }

    public var validKoreanWordCount: Int { validKorean.count }

    public func koreanWords() -> [String] {
        Array(korean)
    }

    /// English dictionary entries whose length is inside `range`. The list is
    /// built once; callers use it at a word boundary, not on every key.
    public func englishWords(length: ClosedRange<Int>) -> [String] {
        indexLock.lock()
        defer { indexLock.unlock() }
        if englishByLength == nil {
            var buckets: [Int: [String]] = [:]
            for word in english {
                buckets[word.count, default: []].append(word)
            }
            englishByLength = buckets
        }
        var result: [String] = []
        for count in length {
            if let bucket = englishByLength?[count] {
                result.append(contentsOf: bucket)
            }
        }
        return result
    }

    public func isAbbreviation(_ text: String) -> Bool {
        guard text.count >= 2, text.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return false }
        return abbreviations.contains(text)
    }

    /// v2, utf8, mp3, i18n, a11y. The number row is jamo on 390, so a single
    /// letter plus one digit ("r2", the middle of 했) is not a version token.
    public func isCodeToken(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"^v\d+$"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"^[a-z]{2,}\d+$"#, options: .regularExpression) != nil {
            let letters = String(lower.prefix { $0.isLetter })
            if letters.contains(where: { "aeiou".contains($0) }) || techStems.contains(letters) {
                return true
            }
        }
        if lower.range(of: #"^[a-z]\d{2,}[a-z]+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    public static func load(from directory: URL) throws -> Lexicon {
        let english = try lines(directory.appendingPathComponent("english-words.txt"))
        let extra = (try? lines(directory.appendingPathComponent("english-extra.txt"))) ?? []
        let korean = try lines(directory.appendingPathComponent("korean-words.txt"))
        let valid = (try? lines(directory.appendingPathComponent("korean-valid.txt"))) ?? []
        return Lexicon(
            english: english + extra,
            korean: korean,
            abbreviations: Self.defaultAbbreviations,
            techStems: Self.defaultTechStems,
            validKorean: valid
        )
    }

    private func lowerBound(_ key: String) -> Int? {
        var low = 0
        var high = english.count
        while low < high {
            let mid = (low + high) / 2
            if english[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < english.count ? low : nil
    }

    private static func lines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static let defaultAbbreviations = [
        "AI", "OK", "UI", "UX", "OS", "ID", "IP", "PC", "TV", "US", "UK", "KR",
        "PR", "CI", "CD", "DB", "IO", "QA", "ML", "API", "URL", "CPU", "GPU",
        "RAM", "SSH", "PDF", "USB", "SQL", "CSS", "HTML", "JSON", "HTTP",
        "HTTPS", "GIF", "PNG", "JPG", "SVG", "XML", "IDE", "CLI", "GUI", "NPM",
        "AWS", "GCP", "JWT", "UTF",
    ]

    public static let defaultTechStems = [
        "mp", "utf", "html", "css", "json", "xml", "http", "https", "ssh", "sql",
        "png", "jpg", "gif", "svg", "pdf", "usb", "cpu", "gpu", "ram", "api",
        "url", "npm", "js", "ts", "io", "id", "os", "ui", "ux", "db", "ip",
    ]
}
