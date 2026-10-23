import Foundation

public enum Language: String, Equatable, Sendable {
    case korean
    case english

    public var flipped: Language { self == .korean ? .english : .korean }
}

public struct SessionUpdate: Equatable, Sendable {
    public var committed: String
    public var preedit: String
    public var mode: Language
    public var didAutoConvert: Bool
    /// When set, replace this many UTF-16 units before the caret with `preedit`
    /// instead of inserting `committed`. Used to undo a conversion that already
    /// left the preedit.
    public var replacePreviousUTF16: Int?
}

public enum InputGate {
    public static func shouldPassThrough(secureInput: Bool, command: Bool, control: Bool, option: Bool) -> Bool {
        secureInput || command || control || option
    }
}

/// One word-in-progress. Each physical key is kept, and the visible text is
/// re-read as QWERTY or as 세벌식 390. A reading changes only when the one in
/// progress stops being plausible and another reading is.
public final class Session {
    public var autoSwitch: Bool
    public private(set) var mode: Language
    public private(set) var committed = ""
    public private(set) var preedit = ""

    public var document: String { committed + preedit }

    private let lexicon: Lexicon
    private var keys: [KeyAtom] = []
    private var segments: [Segment] = []
    private var locked: Language?
    private var pendingUndo: Undo?

    public init(lexicon: Lexicon, autoSwitch: Bool = true, mode: Language = .korean) {
        self.lexicon = lexicon
        self.autoSwitch = autoSwitch
        self.mode = mode
    }

    public func input(_ english: Character) -> SessionUpdate {
        input(Layout390.atom(for: english))
    }

    public func input(_ atom: KeyAtom) -> SessionUpdate {
        if atom.isNeutralBreaker && !continuesAsCode(atom) {
            return finishWord(appending: atom.english)
        }
        pendingUndo = nil
        let previous = segments
        keys.append(atom)
        let converted = recompute(wordFinal: false, previous: previous)
        if converted, let extended = extend(previous, to: keys.count) {
            pendingUndo = Undo(keys: keys, segments: extended, committedSuffix: nil)
        }
        preedit = render(segments)
        return currentUpdate(didAutoConvert: converted)
    }

    public func backspace() -> SessionUpdate {
        pendingUndo = nil
        guard !keys.isEmpty else { return currentUpdate(didAutoConvert: false) }
        keys.removeLast()
        if keys.isEmpty {
            segments = []
            locked = nil
            preedit = ""
            return currentUpdate(didAutoConvert: false)
        }
        _ = recompute(wordFinal: false, previous: nil)
        preedit = render(segments)
        return currentUpdate(didAutoConvert: false)
    }

    /// Caps Lock / Shift+Space. Immediately after an automatic conversion this
    /// restores the previous reading and holds it. Otherwise it flips the
    /// reading of the current word, or the mode for the next word.
    public func toggle() -> SessionUpdate {
        if let undo = pendingUndo {
            pendingUndo = nil
            if let suffix = undo.committedSuffix {
                if committed.hasSuffix(suffix) {
                    committed.removeLast(suffix.count)
                }
                keys = undo.keys
                segments = undo.segments
                locked = undo.segments.last?.lang ?? mode
                mode = locked ?? mode
                preedit = render(segments)
                return SessionUpdate(
                    committed: "",
                    preedit: preedit,
                    mode: mode,
                    didAutoConvert: false,
                    replacePreviousUTF16: utf16Length(suffix)
                )
            }
            keys = undo.keys
            segments = undo.segments
            locked = undo.segments.last?.lang ?? mode
            mode = locked ?? mode
            preedit = render(segments)
            return currentUpdate(didAutoConvert: false)
        }

        if !keys.isEmpty {
            let flipped = (segments.last?.lang ?? mode).flipped
            locked = flipped
            mode = flipped
            segments = [Segment(start: 0, end: keys.count, lang: flipped)]
            preedit = render(segments)
            return currentUpdate(didAutoConvert: false)
        }

        mode = mode.flipped
        locked = nil
        return currentUpdate(didAutoConvert: false)
    }

    /// Commit the visible word without re-scoring it (focus loss, shortcut).
    public func commitDisplayed() -> SessionUpdate {
        pendingUndo = nil
        let text = preedit
        clearToken()
        guard !text.isEmpty else { return currentUpdate(didAutoConvert: false) }
        committed += text
        return SessionUpdate(committed: text, preedit: "", mode: mode, didAutoConvert: false, replacePreviousUTF16: nil)
    }

    public func forceMode(_ language: Language) -> SessionUpdate {
        let update = commitDisplayed()
        mode = language
        locked = nil
        return SessionUpdate(committed: update.committed, preedit: "", mode: mode, didAutoConvert: false, replacePreviousUTF16: nil)
    }

    public func discard() -> SessionUpdate {
        clearToken()
        pendingUndo = nil
        preedit = ""
        return currentUpdate(didAutoConvert: false)
    }

    public var debugLine: String {
        let description = segments.map { "\($0.lang.rawValue):\($0.start)-\($0.end)" }.joined(separator: " ")
        return "\(document) {\(description)} mode=\(mode.rawValue) lock=\(locked?.rawValue ?? "-")"
    }

    private func finishWord(appending breaker: Character) -> SessionUpdate {
        let previous = segments
        let before = render(segments)
        _ = recompute(wordFinal: true, previous: previous.isEmpty ? nil : previous)
        let word = render(segments)
        let suffix = word + String(breaker)
        if word != before && !keys.isEmpty {
            pendingUndo = Undo(keys: keys, segments: previous, committedSuffix: suffix)
        } else {
            pendingUndo = nil
        }
        committed += suffix
        let converted = word != before && !before.isEmpty
        clearToken()
        preedit = ""
        return SessionUpdate(committed: suffix, preedit: "", mode: mode, didAutoConvert: converted, replacePreviousUTF16: nil)
    }

    private func clearToken() {
        keys = []
        segments = []
        locked = nil
        preedit = ""
    }

    @discardableResult
    private func recompute(wordFinal: Bool, previous: [Segment]?) -> Bool {
        if let locked {
            segments = keys.isEmpty ? [] : [Segment(start: 0, end: keys.count, lang: locked)]
            mode = locked
            return false
        }
        if !autoSwitch {
            segments = keys.isEmpty ? [] : [Segment(start: 0, end: keys.count, lang: mode)]
            return false
        }
        guard !keys.isEmpty else {
            segments = []
            return false
        }

        // A later syllable's keys can spell an English word ("력" is y-e-x,
        // and "yex" is a Webster headword). While the buffer is still one or
        // more syllables, optionally with a trailing choseong, it stays Korean.
        if prefersWholeKorean() {
            let korean = [Segment(start: 0, end: keys.count, lang: .korean)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(korean) != render(extended)
            }
            segments = korean
            mode = .korean
            return changed
        }

        // Shifted 390 digits sit on letter keys (1 is M, 0 is N). "MN" is an
        // English prefix, so it must not outrank the digits while typing Korean.
        if prefersPadDigits() {
            let korean = [Segment(start: 0, end: keys.count, lang: .korean)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(korean) != render(extended)
            }
            segments = korean
            mode = .korean
            return changed
        }

        // "agents.md" and "https://agents.md" are one token. A dot only ends
        // the word when the buffer is already a Hangul syllable.
        if prefersWholeEnglishCode() {
            let english = [Segment(start: 0, end: keys.count, lang: .english)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(english) != render(extended)
            }
            segments = english
            mode = .english
            return changed
        }

        // "agents" is still a prefix of "agentship", and "nts" is the syllable
        // 선. A pure letter run that is a word or a prefix stays one English
        // reading. "AIyv" is not a prefix, so 로 can still take the tail.
        if prefersWholeEnglishWord() {
            let english = [Segment(start: 0, end: keys.count, lang: .english)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(english) != render(extended)
            }
            segments = english
            mode = .english
            return changed
        }

        let chosen = bestPath(wordFinal: wordFinal) ?? [Segment(start: 0, end: keys.count, lang: mode)]
        if let previous, let extended = extend(previous, to: keys.count) {
            let extendedScore = score(extended, wordFinal: wordFinal)
            let extendedSolid = lastIsSolid(extended, wordFinal: wordFinal)
            let reserved = reservesEnglishPrefix(extended, wordFinal: wordFinal)
            let chosenScore = score(chosen, wordFinal: wordFinal) ?? Int.min
            let takeNew: Bool
            if extendedSolid || reserved {
                takeNew = false
            } else if extendedScore == nil {
                takeNew = true
            } else {
                takeNew = chosenScore > extendedScore! + Scoring.margin
            }
            if takeNew {
                let changed = render(chosen) != render(extended)
                segments = chosen
                mode = segments.last?.lang ?? mode
                return changed
            }
            segments = extended
            mode = segments.last?.lang ?? mode
            return false
        }

        segments = chosen
        mode = segments.last?.lang ?? mode
        return false
    }

    private func bestPath(wordFinal: Bool) -> [Segment]? {
        let count = keys.count
        guard count > 0 else { return nil }
        var best: [Path?] = Array(repeating: nil, count: count + 1)
        best[0] = Path(score: 0, prev: -1, lang: mode)
        let order: [Language] = mode == .korean ? [.korean, .english] : [.english, .korean]

        for start in 0..<count {
            guard let base = best[start] else { continue }
            let limit = min(count, start + Scoring.maxSegment)
            if limit <= start { continue }
            for end in (start + 1)...limit {
                for lang in order {
                    if lang == .english && continuesKoreanSyllable(at: start) { continue }
                    let isFinal = wordFinal && end == count
                    guard let quality = self.quality(start..<end, lang: lang, wordFinal: isFinal) else { continue }
                    var total = base.score + quality.score
                    if start > 0 {
                        total -= Scoring.joinPenalty
                        if lang != base.lang {
                            total -= Scoring.switchPenalty
                        }
                    }
                    if start == 0 && lang == mode {
                        total += Scoring.modeBonus
                    }
                    if best[end] == nil || total > best[end]!.score {
                        best[end] = Path(score: total, prev: start, lang: lang)
                    }
                }
            }
        }
        guard best[count] != nil else { return nil }
        var parts: [Segment] = []
        var cursor = count
        while cursor > 0 {
            guard let path = best[cursor] else { return nil }
            parts.append(Segment(start: path.prev, end: cursor, lang: path.lang))
            cursor = path.prev
        }
        return parts.reversed()
    }

    private func score(_ parts: [Segment], wordFinal: Bool) -> Int? {
        guard !parts.isEmpty else { return 0 }
        var total = 0
        for (index, part) in parts.enumerated() {
            let isFinal = wordFinal && index == parts.count - 1
            guard let quality = quality(part.start..<part.end, lang: part.lang, wordFinal: isFinal) else { return nil }
            total += quality.score
            if index > 0 {
                total -= Scoring.joinPenalty
                if parts[index - 1].lang != part.lang {
                    total -= Scoring.switchPenalty
                }
            }
        }
        if parts[0].lang == mode {
            total += Scoring.modeBonus
        }
        return total
    }

    private func lastIsSolid(_ parts: [Segment], wordFinal: Bool) -> Bool {
        guard let last = parts.last else { return false }
        return quality(last.start..<last.end, lang: last.lang, wordFinal: wordFinal)?.solid == true
    }

    private func reservesEnglishPrefix(_ parts: [Segment], wordFinal: Bool) -> Bool {
        if wordFinal { return false }
        guard let last = parts.last, last.lang == .english else { return false }
        let text = englishText(last.start..<last.end)
        let lower = text.lowercased()
        guard lower.count >= 2, lower.allSatisfy(\.isLetter) else { return false }
        guard lower.contains(where: { "aeiou".contains($0) }) else { return false }
        if lexicon.isEnglishWord(lower) { return false }
        guard lexicon.isEnglishPrefix(lower) else { return false }
        return lower.count >= 3 || mode == .english
    }

    private func quality(_ range: Range<Int>, lang: Language, wordFinal: Bool) -> ReadingQuality? {
        switch lang {
        case .english:
            // A run of nothing but 390 digit keys is not an English word.
            // "AI" still is: only the I key is a digit, and the abbreviation stands.
            if mode == .korean, !keys[range].isEmpty, keys[range].allSatisfy(isPadDigit) {
                return nil
            }
            return englishQuality(englishText(range), wordFinal: wordFinal)
        case .korean:
            return koreanQuality(keys[range], wordFinal: wordFinal)
        }
    }

    private func englishQuality(_ text: String, wordFinal: Bool) -> ReadingQuality? {
        if text.isEmpty { return nil }
        if lexicon.isAbbreviation(text) {
            return ReadingQuality(score: 230 + text.count, solid: true)
        }
        if lexicon.isCodeToken(text) {
            let strong = text.count >= 4 || text.lowercased().hasPrefix("v")
            return ReadingQuality(score: strong ? 210 : 96, solid: strong)
        }
        if text.allSatisfy(\.isNumber) {
            // One number-row key is a jamo. A run of them ("2024") is a number.
            if text.count == 1 {
                return ReadingQuality(score: 18, solid: false)
            }
            return ReadingQuality(score: 90 + text.count * 4, solid: true)
        }
        if lexicon.isEnglishWord(text.lowercased()), text.contains(where: \.isNumber) {
            return ReadingQuality(score: 200 + text.count, solid: true)
        }
        if let apostrophe = apostropheQuality(text, wordFinal: wordFinal) {
            return apostrophe
        }
        let lower = text.lowercased()
        if lower.allSatisfy(\.isLetter), lexicon.isEnglishWord(lower) {
            if lower.count >= 3 {
                return ReadingQuality(score: 172 + lower.count * 8, solid: true)
            }
            if lower.count == 2 {
                return ReadingQuality(score: 64, solid: false)
            }
        }
        if !wordFinal, lower.count >= 2, lower.allSatisfy(\.isLetter), lexicon.isEnglishPrefix(lower), !lexicon.isEnglishWord(lower) {
            let vowel = lower.contains { "aeiou".contains($0) }
            return ReadingQuality(score: (vowel ? 28 : 14) + lower.count * 2, solid: false)
        }
        if text.count == 1, let first = text.first, first.isLetter || first.isNumber {
            return ReadingQuality(score: wordFinal ? 12 : 20, solid: false)
        }
        if text.count == 1 {
            return ReadingQuality(score: 10, solid: false)
        }
        return nil
    }

    private func apostropheQuality(_ text: String, wordFinal: Bool) -> ReadingQuality? {
        let lower = text.lowercased()
        guard lower.filter({ $0 == "'" }).count == 1, let mark = lower.firstIndex(of: "'") else { return nil }
        let left = String(lower[..<mark])
        let right = String(lower[lower.index(after: mark)...])
        guard left.allSatisfy(\.isLetter), !left.isEmpty else { return nil }
        let endings = ["t", "s", "re", "ve", "ll", "d", "m"]
        if endings.contains(right), lexicon.isEnglishWord(left) || lexicon.isEnglishPrefix(left) {
            let solid = lexicon.isEnglishWord(left)
            return ReadingQuality(score: 200 + lower.count, solid: solid)
        }
        if right.isEmpty, !wordFinal, lexicon.isEnglishWord(left) || lexicon.isEnglishPrefix(left) {
            return ReadingQuality(score: 30 + left.count * 2, solid: false)
        }
        return nil
    }

    private func koreanQuality(_ atoms: ArraySlice<KeyAtom>, wordFinal: Bool) -> ReadingQuality? {
        let composition = Composer.compose(atoms)
        switch shape(of: composition.pieces) {
        case .invalid:
            return nil
        case .symbol:
            return ReadingQuality(score: 14, solid: false)
        case .singleBare:
            // A choseong, including ㄲ·ㄸ·ㅃ, can still open a syllable.
            // A lone jungseong or jongseong cannot ("x" is ㄱ). A finished
            // word that never became a syllable is not Korean either ("k ").
            if wordFinal || composition.pieces != [.bareChoseong] {
                return nil
            }
            return ReadingQuality(score: 26, solid: false)
        case .trailing(let syllables):
            return ReadingQuality(score: 34 + syllables * 8, solid: false)
        case .digits:
            // English mode keeps the QWERTY letters (MN, API). Korean mode
            // reads this same key run as digits.
            if mode == .english { return nil }
            return ReadingQuality(score: 48 + composition.pieces.count * 6, solid: composition.pieces.count >= 2)
        case .clean(let syllables):
            var score = 100 + max(0, syllables - 1) * 24
            if syllables >= 2, lexicon.isKoreanWord(composition.text) {
                score += 40
            }
            return ReadingQuality(score: score, solid: syllables >= 2)
        }
    }

    /// "she" must not borrow the ㄴ of 안. A jongseong that changes the
    /// previous syllable in place is still that syllable.
    private func continuesKoreanSyllable(at index: Int) -> Bool {
        guard index > 0 else { return false }
        guard case .jamo(let incoming) = keys[index].korean, incoming.kind == .jongseong else { return false }
        let from = max(0, index - 4)
        let head = Composer.compose(keys[from..<index])
        let full = Composer.compose(keys[from...index])
        return full.pieces.last == .syllable && full.text.count == head.text.count && full.text != head.text
    }

    /// The buffer is still a Korean word being typed: one or more syllables,
    /// optionally with the first consonant of the next syllable. English words
    /// made of those same keys ("yex", "ivy", "uvr2") do not get to interrupt it.
    /// A reading that is not a syllable anymore ("hello", "other", "deploy")
    /// falls through and can switch.
    private func prefersWholeKorean() -> Bool {
        switch bufferShape() {
        case .clean(let syllables), .trailing(let syllables):
            return syllables >= 1
        default:
            return false
        }
    }

    /// Filenames, URLs, domains, paths, and emails are one English token.
    /// Interior punctuation does not open a new language decision, so "md"
    /// after a dot is not free to become the syllable 히.
    private func prefersWholeEnglishCode() -> Bool {
        let text = englishText(0..<keys.count)
        guard text.contains(where: { CodeToken.interior.contains($0) }) else { return false }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || CodeToken.interior.contains($0) }) else { return false }
        let labels = text.split { CodeToken.interior.contains($0) }
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { labelStaysEnglish(String($0)) }
    }

    private func labelStaysEnglish(_ label: String) -> Bool {
        let lower = label.lowercased()
        // One syllable stays in the token: "md" is 히, and a file extension is
        // the same shape. Two syllables are Korean unless they are a real
        // English word. 요 sits on the 4 key, so a Hangul word must not be
        // kept just because it looks like a version token.
        guard cleanSyllableCount(label) >= 2 else { return true }
        return lower.allSatisfy(\.isLetter) && lexicon.isEnglishWord(lower)
    }

    /// The whole buffer is one English letter run: a word, or the start of one.
    /// Checked only after Hangul stickiness, so 입력 and 녀 stay Korean.
    /// An all-digit pad run is handled first, so "MN" is not read as a prefix.
    private func prefersWholeEnglishWord() -> Bool {
        let lower = englishText(0..<keys.count).lowercased()
        guard lower.count >= 2, lower.allSatisfy(\.isLetter) else { return false }
        return lexicon.isEnglishWord(lower) || lexicon.isEnglishPrefix(lower)
    }

    /// Korean-mode run of shifted 390 digit keys (M N U I O J K L < >).
    private func prefersPadDigits() -> Bool {
        mode == .korean && !keys.isEmpty && keys.allSatisfy(isPadDigit)
    }

    private func isPadDigit(_ atom: KeyAtom) -> Bool {
        if case .character(let character) = atom.korean {
            return character.isNumber
        }
        return false
    }

    private func cleanSyllableCount(_ text: String) -> Int {
        let atoms = text.map { Layout390.atom(for: $0) }
        if case .clean(let count) = shape(of: Composer.compose(atoms).pieces) {
            return count
        }
        return 0
    }

    /// A period after Hangul commits the word. A period inside an English or
    /// dotted token ("agents.md", "a.b.c", "https://…") stays in the preedit.
    private func continuesAsCode(_ atom: KeyAtom) -> Bool {
        guard autoSwitch, locked == nil, !keys.isEmpty else { return false }
        guard CodeToken.joiners.contains(atom.english) else { return false }
        if !segments.isEmpty, segments.allSatisfy({ $0.lang == .english }) {
            return true
        }
        guard keys.count == 1, CodeToken.starters.contains(atom.english) else { return false }
        if case .singleBare = bufferShape() { return true }
        return false
    }

    private func bufferShape() -> Shape {
        shape(of: Composer.compose(keys).pieces)
    }

    private func englishText(_ range: Range<Int>) -> String {
        String(keys[range].map(\.english))
    }

    private func render(_ parts: [Segment]) -> String {
        parts.map { part in
            let slice = keys[part.start..<part.end]
            switch part.lang {
            case .english:
                return String(slice.map(\.english))
            case .korean:
                return Composer.compose(slice).text
            }
        }.joined()
    }

    private func extend(_ parts: [Segment], to count: Int) -> [Segment]? {
        guard var last = parts.last else { return nil }
        if last.end == count { return parts }
        guard last.end == count - 1, last.start < count else { return nil }
        last.end = count
        var copy = parts
        copy[copy.count - 1] = last
        return copy
    }

    private func currentUpdate(didAutoConvert: Bool) -> SessionUpdate {
        SessionUpdate(committed: "", preedit: preedit, mode: mode, didAutoConvert: didAutoConvert, replacePreviousUTF16: nil)
    }

    private func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }
}

private struct ReadingQuality {
    var score: Int
    var solid: Bool
}

private struct Segment {
    var start: Int
    var end: Int
    var lang: Language
}

private struct Path {
    var score: Int
    var prev: Int
    var lang: Language
}

private struct Undo {
    var keys: [KeyAtom]
    var segments: [Segment]
    var committedSuffix: String?
}

private enum Shape {
    case invalid
    case singleBare
    case trailing(syllables: Int)
    case digits
    case clean(syllables: Int)
    case symbol
}

private func shape(of pieces: [CompositionPiece]) -> Shape {
    if pieces.isEmpty { return .invalid }
    if pieces.allSatisfy({ $0 == .symbol }) { return pieces.count == 1 ? .symbol : .invalid }
    if pieces.contains(.symbol) { return .invalid }
    if pieces.allSatisfy({ $0 == .digit }) { return .digits }

    func isBare(_ piece: CompositionPiece) -> Bool {
        switch piece {
        case .bareChoseong, .bareJungseong, .bareJongseong: return true
        default: return false
        }
    }

    if pieces.count == 1, isBare(pieces[0]) { return .singleBare }

    var body = pieces
    var trailing = false
    if body.last == .bareChoseong {
        body.removeLast()
        trailing = true
    }
    if body.contains(where: isBare) { return .invalid }
    guard body.allSatisfy({ $0 == .syllable || $0 == .digit }) else { return .invalid }
    let syllables = body.reduce(0) { $0 + ($1 == .syllable ? 1 : 0) }
    if trailing {
        return syllables > 0 ? .trailing(syllables: syllables) : .invalid
    }
    return syllables > 0 ? .clean(syllables: syllables) : .invalid
}

private enum CodeToken {
    /// Breakers that stay inside a filename, URL, email, or identifier.
    static let joiners: Set<Character> = [".", ":", "@", "_", "-", "+", "?", "=", "&", "%", "#"]
    /// A lone bare jamo plus one of these is a dotted label ("a.b"), not a word.
    static let starters: Set<Character> = [".", ":", "@", "_", "-", "+"]
    /// Same as joiners, plus "/" which is already inside the token (it is ㅗ on 390).
    static let interior: Set<Character> = [".", ":", "/", "@", "_", "-", "+", "?", "=", "&", "%", "#"]
}

private enum Scoring {
    /// How far a new segmentation must lead before it replaces the reading
    /// already on screen.
    static let margin = 28
    /// Cost of a language change inside one token.
    static let switchPenalty = 48
    /// Cost of every extra piece. Without this, 하+ㄴ outscores 한.
    static let joinPenalty = 64
    static let modeBonus = 16
    static let maxSegment = 24
}
