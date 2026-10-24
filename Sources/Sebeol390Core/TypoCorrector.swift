import Foundation

/// Endings stripped only to decide that a stem is already a dictionary word.
enum KoreanEndings {
    static let longestFirst = [
        "에서", "으로", "하고", "하는",
        "는", "은", "이", "가", "를", "을", "에", "로",
        "와", "과", "도", "만", "의", "했", "해",
    ]
    static let set = Set(longestFirst)

    static func split(_ word: String) -> (stem: String, ending: String)? {
        let word = word.precomposedStringWithCanonicalMapping
        for ending in longestFirst where word.count > ending.count && word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            if !stem.isEmpty {
                return (stem, ending)
            }
        }
        return nil
    }
}

/// One confident dictionary replacement for a finished word, or nil.
/// Costs are millicosts so the margin does not depend on binary fractions.
/// A short word allows a single cheap edit. A long one allows two.
public enum TypoCorrector {
    public static func correction(
        composed: String,
        keys: [KeyAtom],
        language: Language,
        lexicon: Lexicon,
        memory: (any TypoMemory)?
    ) -> String? {
        let composed = composed.precomposedStringWithCanonicalMapping
        guard !composed.isEmpty else { return nil }
        switch language {
        case .korean:
            return korean(composed: composed, keys: keys, lexicon: lexicon, memory: memory)
        case .english:
            return english(composed: composed, lexicon: lexicon, memory: memory)
        }
    }

    private static func korean(
        composed: String,
        keys: [KeyAtom],
        lexicon: Lexicon,
        memory: (any TypoMemory)?
    ) -> String? {
        if isKnownKorean(composed, lexicon: lexicon) { return nil }
        if let logged = loggedKorean(composed, memory: memory, lexicon: lexicon) {
            return logged
        }
        guard let typed = Composer.jamoSequence(keys), !typed.isEmpty else { return nil }
        let typedUnits = typed.map { JamoUnit(kind: $0.kind, scalar: $0.scalar) }
        guard jungCount(typedUnits) >= 2, modernSyllableCount(composed) >= 1 else { return nil }

        let limit = typedUnits.count >= 8 ? longLimit : shortLimit
        var found: [String: Int] = [:]
        let entries = koreanEntries(lexicon)

        func consider(_ text: String, _ cost: Int) {
            guard text != composed, (1...limit).contains(cost) else { return }
            if let old = found[text], old <= cost { return }
            found[text] = cost
        }

        if let (stem, ending) = KoreanEndings.split(composed),
           let stemKeys = stemKeys(in: keys, stem: stem, ending: ending),
           let stemUnits = Composer.jamoSequence(stemKeys)?.map({ JamoUnit(kind: $0.kind, scalar: $0.scalar) }),
           jungCount(stemUnits) >= 2 {
            for entry in entries {
                let cost = editCost(stemUnits, entry.units, limit: limit, substitute: jamoCost, allowTranspose: false)
                consider(entry.word + ending, cost)
            }
        }
        for entry in entries {
            let cost = editCost(typedUnits, entry.units, limit: limit, substitute: jamoCost, allowTranspose: false)
            consider(entry.word, cost)
        }
        return uniqueWinner(found)
    }

    private static func english(composed: String, lexicon: Lexicon, memory: (any TypoMemory)?) -> String? {
        guard composed.allSatisfy(\.isLetter), composed.count >= 2 else { return nil }
        if composed.allSatisfy(\.isUppercase) { return nil }
        if composed.dropFirst().contains(where: \.isUppercase) { return nil }
        let lower = composed.lowercased()
        if lexicon.isEnglishWord(lower) || lexicon.isAbbreviation(composed) || lexicon.isCodeToken(composed) {
            return nil
        }
        if let logged = memory?.uniqueFinal(for: composed) ?? memory?.uniqueFinal(for: lower) {
            let loggedLower = logged.lowercased()
            if loggedLower != lower, logged.allSatisfy(\.isLetter), lexicon.isEnglishWord(loggedLower) {
                return matchingCase(loggedLower, like: composed)
            }
        }
        guard lower.count >= 4 else { return nil }
        let source = Array(lower)
        let limit = source.count >= 8 ? longLimit : shortLimit
        let band = max(1, source.count - 1)...(source.count + 1)
        var found: [String: Int] = [:]
        for candidate in lexicon.englishWords(length: band) {
            guard candidate != lower else { continue }
            let cost = editCost(source, Array(candidate), limit: limit, substitute: letterCost, allowTranspose: true)
            guard (1...limit).contains(cost) else { continue }
            if let old = found[candidate], old <= cost { continue }
            found[candidate] = cost
        }
        guard let winner = uniqueWinner(found) else { return nil }
        let cased = matchingCase(winner, like: composed)
        return cased == composed ? nil : cased
    }

    private static func loggedKorean(_ composed: String, memory: (any TypoMemory)?, lexicon: Lexicon) -> String? {
        guard let logged = memory?.uniqueFinal(for: composed), logged != composed else { return nil }
        guard isHangulReading(logged), isKnownKorean(logged, lexicon: lexicon) else { return nil }
        return logged
    }

    private static func isKnownKorean(_ word: String, lexicon: Lexicon) -> Bool {
        if lexicon.isKoreanWord(word) { return true }
        if let (stem, _) = KoreanEndings.split(word), lexicon.isKoreanWord(stem) { return true }
        return false
    }

    private static func isHangulReading(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (0xAC00...0xD7A3).contains(value) || (0x3131...0x318E).contains(value)
        }
    }

    private static func modernSyllableCount(_ word: String) -> Int {
        word.unicodeScalars.reduce(0) { count, scalar in
            (0xAC00...0xD7A3).contains(scalar.value) ? count + 1 : count
        }
    }

    private static func matchingCase(_ replacement: String, like source: String) -> String {
        guard let first = source.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func uniqueWinner(_ found: [String: Int]) -> String? {
        let ranked = found.values.sorted()
        guard let bestCost = ranked.first else { return nil }
        let winners = found.compactMap { $0.value == bestCost ? $0.key : nil }
        guard winners.count == 1 else { return nil }
        let second = ranked.dropFirst().first ?? Int.max
        guard second > bestCost + margin else { return nil }
        return winners[0]
    }

    private static func stemKeys(in keys: [KeyAtom], stem: String, ending: String) -> [KeyAtom]? {
        for index in 0...keys.count {
            let head = Composer.compose(keys[..<index]).text.precomposedStringWithCanonicalMapping
            let tail = Composer.compose(keys[index...]).text.precomposedStringWithCanonicalMapping
            if head == stem && tail == ending {
                return Array(keys[..<index])
            }
        }
        return nil
    }

    private static func jungCount(_ units: [JamoUnit]) -> Int {
        units.reduce(0) { $0 + ($1.kind == .jungseong ? 1 : 0) }
    }

    private struct JamoUnit: Equatable {
        var kind: JamoKind
        var scalar: UInt32

        var jamo: Jamo { Jamo(scalar: scalar, kind: kind) }
    }

    private struct KoreanEntry {
        var word: String
        var units: [JamoUnit]
    }

    /// One cheap substitution. An inserted jamo (850) stays out, so 갔어 is
    /// not rewritten as 갔었.
    private static let shortLimit = 700
    private static let longLimit = 1500
    private static let margin = 250
    private static let insertCost = 850
    private static let transposeCost = 700
    private static let genericCost = 2000

    private static func jamoCost(_ left: JamoUnit, _ right: JamoUnit) -> Int {
        if left == right { return 0 }
        var best = genericCost
        if let a = consonant(left), let b = consonant(right), a.base == b.base {
            if a.series == b.series, left.kind != right.kind {
                best = min(best, 550)
            }
            if a.series != b.series, Set([a.series, b.series]).isSubset(of: [0, 1]) {
                best = min(best, 550)
            }
            if Set([a.series, b.series]) == [0, 2] {
                best = min(best, 600)
            }
        }
        if let leftKey = canonicalKey[left.jamo], let rightKey = canonicalKey[right.jamo], orthogonal(leftKey, rightKey) {
            best = min(best, 550)
        }
        if Hangul.differsByOneComponent(left.jamo, right.jamo) {
            best = min(best, 850)
        }
        return best
    }

    private static func letterCost(_ left: Character, _ right: Character) -> Int {
        if left == right { return 0 }
        return orthogonal(left, right) ? 550 : genericCost
    }

    private struct Consonant {
        var base: Int
        var series: Int
    }

    /// series 0 plain, 1 tense, 2 aspirated. Same base and series on the
    /// other side of 390 is the cho/jong slip.
    private static func consonant(_ unit: JamoUnit) -> Consonant? {
        switch unit.scalar {
        case 0x1100, 0x11A8: return Consonant(base: 0, series: 0) // ㄱ
        case 0x1101, 0x11A9: return Consonant(base: 0, series: 1) // ㄲ
        case 0x110F, 0x11BF: return Consonant(base: 0, series: 2) // ㅋ
        case 0x1103, 0x11AE: return Consonant(base: 1, series: 0) // ㄷ
        case 0x1104: return Consonant(base: 1, series: 1) // ㄸ
        case 0x1110, 0x11C0: return Consonant(base: 1, series: 2) // ㅌ
        case 0x1107, 0x11B8: return Consonant(base: 2, series: 0) // ㅂ
        case 0x1108: return Consonant(base: 2, series: 1) // ㅃ
        case 0x1111, 0x11C1: return Consonant(base: 2, series: 2) // ㅍ
        case 0x1109, 0x11BA: return Consonant(base: 3, series: 0) // ㅅ
        case 0x110A, 0x11BB: return Consonant(base: 3, series: 1) // ㅆ
        case 0x110C, 0x11BD: return Consonant(base: 4, series: 0) // ㅈ
        case 0x110D: return Consonant(base: 4, series: 1) // ㅉ
        case 0x110E, 0x11BE: return Consonant(base: 4, series: 2) // ㅊ
        case 0x1102, 0x11AB: return Consonant(base: 5, series: 0) // ㄴ
        case 0x1105, 0x11AF: return Consonant(base: 6, series: 0) // ㄹ
        case 0x1106, 0x11B7: return Consonant(base: 7, series: 0) // ㅁ
        case 0x110B, 0x11BC: return Consonant(base: 8, series: 0) // ㅇ
        case 0x1112, 0x11C2: return Consonant(base: 9, series: 0) // ㅎ
        default: return nil
        }
    }

    private static func editCost<T: Equatable>(
        _ left: [T],
        _ right: [T],
        limit: Int,
        substitute: (T, T) -> Int,
        allowTranspose: Bool
    ) -> Int {
        if left == right { return 0 }
        let lengthGap = abs(left.count - right.count)
        if lengthGap * insertCost > limit { return limit + 1 }
        let columns = right.count + 1
        var previousPrevious = [Int]()
        var previous = Array(0..<columns).map { $0 * insertCost }
        var current = Array(repeating: 0, count: columns)
        for row in 1...left.count {
            current[0] = row * insertCost
            var rowMin = current[0]
            for column in 1...right.count {
                var best = min(
                    previous[column - 1] + substitute(left[row - 1], right[column - 1]),
                    previous[column] + insertCost,
                    current[column - 1] + insertCost
                )
                if allowTranspose, row > 1, column > 1,
                   left[row - 1] == right[column - 2], left[row - 2] == right[column - 1] {
                    best = min(best, previousPrevious[column - 2] + transposeCost)
                }
                current[column] = best
                rowMin = min(rowMin, best)
            }
            if rowMin > limit { return limit + 1 }
            previousPrevious = previous
            previous = current
        }
        return previous[right.count]
    }

    private static func syllableUnits(_ word: String) -> [JamoUnit]? {
        var units: [JamoUnit] = []
        for character in word.precomposedStringWithCanonicalMapping {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
            let value = scalar.value
            guard (0xAC00...0xD7A3).contains(value) else { return nil }
            let code = value - 0xAC00
            units.append(JamoUnit(kind: .choseong, scalar: 0x1100 + code / 588))
            units.append(JamoUnit(kind: .jungseong, scalar: 0x1161 + (code % 588) / 28))
            let jong = code % 28
            if jong > 0 {
                units.append(JamoUnit(kind: .jongseong, scalar: 0x11A8 + jong - 1))
            }
        }
        return units
    }

    private final class EntryCache: @unchecked Sendable {
        let lock = NSLock()
        var stored: [ObjectIdentifier: (count: Int, entries: [KoreanEntry])] = [:]
    }

    private static let entryCache = EntryCache()

    private static func koreanEntries(_ lexicon: Lexicon) -> [KoreanEntry] {
        entryCache.lock.lock()
        defer { entryCache.lock.unlock() }
        let key = ObjectIdentifier(lexicon)
        if let hit = entryCache.stored[key], hit.count == lexicon.koreanWordCount {
            return hit.entries
        }
        let entries = lexicon.koreanWords().compactMap { word -> KoreanEntry? in
            guard let units = syllableUnits(word) else { return nil }
            return KoreanEntry(word: word, units: units)
        }
        entryCache.stored[key] = (lexicon.koreanWordCount, entries)
        return entries
    }

    private static let canonicalKey: [Jamo: Character] = {
        var map: [Jamo: Character] = [:]
        for character in Array("abcdefghijklmnopqrstuvwxyz") {
            if case .jamo(let jamo) = Layout390.atom(for: character).korean {
                map[jamo] = character
            }
        }
        let rest = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?")
        for character in rest {
            if case .jamo(let jamo) = Layout390.atom(for: character).korean, map[jamo] == nil {
                map[jamo] = character
            }
        }
        return map
    }()

    private static let keyPosition: [Character: (Int, Int)] = {
        let rows = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"]
        var map: [Character: (Int, Int)] = [:]
        for (row, keys) in rows.enumerated() {
            for (column, character) in keys.enumerated() {
                map[character] = (row, column)
            }
        }
        return map
    }()

    /// Shares an edge. A diagonal pair such as ㄱ(k) and ㅎ(m) is left alone,
    /// so 갔어 is not rewritten as 했어.
    private static func orthogonal(_ left: Character, _ right: Character) -> Bool {
        guard let a = keyPosition[left], let b = keyPosition[right] else { return false }
        return abs(a.0 - b.0) + abs(a.1 - b.1) == 1
    }
}
