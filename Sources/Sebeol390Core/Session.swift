import Foundation

public enum Language: String, Equatable, Sendable {
    case korean
    case english

    public var flipped: Language { self == .korean ? .english : .korean }
}

/// What the field should do with this key. English is inserted as ordinary
/// text. Only an open Hangul composition is marked, so an address bar does
/// not treat Latin letters as inline composition.
public enum FieldEdit: Equatable, Sendable {
    /// Do not touch the field.
    case none
    /// Confirm the marked Hangul by inserting the same characters. Nothing is rewritten.
    case unmark(String)
    /// `insertText`. Replaces the marked range when one exists; otherwise appends.
    case insert(String)
    /// `setMarkedText`, replacing the current marked range.
    case mark(String)
    /// `setMarkedText`, replacing this many UTF-16 units before the caret.
    /// There is no marked range.
    case replaceBeforeCaret(utf16: Int, text: String)
    /// Insert `insert` (replacing the marked range), then mark `mark`.
    case insertThenMark(insert: String, mark: String)
    /// `insertText` over this many UTF-16 units before the caret.
    case insertReplacing(utf16: Int, text: String)
    /// Replace this many UTF-16 units with `insert`, then mark `mark`.
    case insertReplacingThenMark(utf16: Int, insert: String, mark: String)
    /// Clear the marked range, then replace this many committed UTF-16 units
    /// with committed `text`.
    case clearMarkThenInsert(utf16: Int, text: String)
    /// Clear the marked range, then replace this many committed UTF-16 units
    /// with marked `text`.
    case clearMarkThenMark(utf16: Int, text: String)
    /// Replace the open token, counted back from the caret through the mark
    /// and the committed prefix, with committed `text` and then `thenMark`.
    case rewrite(utf16: Int, text: String, thenMark: String)

    /// Navigation can deliver the key unchanged: nothing is rewritten.
    public var preservesCharacters: Bool {
        switch self {
        case .none, .unmark:
            return true
        default:
            return false
        }
    }

    /// Two client calls in one key can insert the same characters twice,
    /// because the second call still sees the selection from before the first.
    var sendsMoreThanOneEdit: Bool {
        switch self {
        case .insertThenMark, .insertReplacingThenMark, .clearMarkThenInsert, .clearMarkThenMark:
            return true
        case .rewrite(_, _, let thenMark):
            return !thenMark.isEmpty
        default:
            return false
        }
    }
}

public struct SessionUpdate: Equatable, Sendable {
    public var mode: Language
    public var didAutoConvert: Bool
    /// Marked Hangul after this update. Empty when nothing is in composition.
    public var preedit: String
    public var field: FieldEdit
}

public enum InputGate {
    public static func shouldPassThrough(secureInput: Bool, command: Bool, control: Bool, option: Bool) -> Bool {
        secureInput || command || control || option
    }
}

/// One word-in-progress. Each physical key is kept, and the visible text is
/// re-read as QWERTY or as 세벌식 390. A reading changes only when the one in
/// progress stops being plausible and another reading is.
///
/// Latin text is inserted immediately. `preedit` is only the Hangul syllable
/// still being composed, so arrow keys never confirm an English composition.
public final class Session {
    public var autoSwitch: Bool
    /// When false, a finished word stays as typed. Retype logging still runs.
    public var correctsTypos = true
    public private(set) var mode: Language
    /// Hangul still open. Empty while the current token is English, digits, or finished.
    public private(set) var preedit = ""

    public var document: String { finished + plain + preedit }

    private let lexicon: Lexicon
    private var keys: [KeyAtom] = []
    private var segments: [Segment] = []
    /// Language at the start of the open word. A lone jungseong such as ㅠ
    /// is typed as its QWERTY key and flips `mode`, but the word is still
    /// the Korean word the user started.
    private var wordMode: Language
    private var locked: Language?
    private var pendingUndo: Undo?
    /// Closed words, already inserted.
    private var finished = ""
    /// Open-token prefix already inserted. The marked syllable, if any, follows it.
    private var plain = ""
    private let typos: (any TypoMemory)?
    /// First backspace in this word, before the user retypes.
    private var rejected: Rejection?
    /// Language of the previous word in this run. Nil after a sentence or newline.
    private var contextLanguage: Language?
    /// `contextLanguage` as it was when the open word started. Undo puts it back.
    private var contextAtWordStart: Language?
    /// Korean reading to restore when a function word was kept in English.
    private var preferredUndo: [Segment]?

    public init(lexicon: Lexicon, autoSwitch: Bool = true, mode: Language = .korean, typos: (any TypoMemory)? = nil) {
        self.lexicon = lexicon
        self.autoSwitch = autoSwitch
        self.mode = mode
        self.wordMode = mode
        self.typos = typos
    }

    public func input(_ english: Character) -> SessionUpdate {
        input(Layout390.atom(for: english))
    }

    public func input(_ atom: KeyAtom) -> SessionUpdate {
        if atom.isNeutralBreaker && !continuesAsCode(atom) {
            return finishWord(appending: atom.english)
        }
        pendingUndo = nil
        if keys.isEmpty {
            wordMode = mode
            contextAtWordStart = contextLanguage
        }
        let previous = segments
        keys.append(atom)
        let converted = recompute(wordFinal: false, previous: previous)
        if let undoSegments = preferredUndo {
            preferredUndo = nil
            pendingUndo = Undo(keys: keys, segments: undoSegments, committedSuffix: nil)
        } else if converted, let extended = extend(previous, to: keys.count) {
            pendingUndo = Undo(keys: keys, segments: extended, committedSuffix: nil)
        }
        return syncClient(didAutoConvert: converted)
    }

    public func backspace() -> SessionUpdate {
        pendingUndo = nil
        if rejected == nil, !keys.isEmpty {
            let text = render(segments)
            if !text.isEmpty {
                rejected = Rejection(keys: keys, text: text)
            }
        }
        guard !keys.isEmpty else { return make(.none, marked: preedit, didAutoConvert: false) }
        let before = document
        keys.removeLast()
        if keys.isEmpty {
            segments = []
            locked = nil
            rejected = nil
        } else {
            _ = recompute(wordFinal: false, previous: nil)
        }
        let (nextPlain, nextMarked) = clientSplit()
        let after = finished + nextPlain + nextMarked
        // The letter is already in the field. Let the app delete it when that
        // is exactly what the new reading is, so autocomplete sees a real delete.
        if preedit.isEmpty, before.hasPrefix(after), utf16Length(before) == utf16Length(after) + 1 {
            plain = nextPlain
            preedit = nextMarked
            return make(.none, marked: preedit, didAutoConvert: false)
        }
        return emit(toPlain: nextPlain, toMarked: nextMarked, didAutoConvert: false)
    }

    /// Shift+Space / Caps Lock. Immediately after an automatic conversion or
    /// typo correction this restores what was typed and holds it. Otherwise
    /// it flips the reading of the current word, or the mode for the next word.
    public func toggle() -> SessionUpdate {
        if let undo = pendingUndo {
            pendingUndo = nil
            if let suffix = undo.committedSuffix {
                if finished.hasSuffix(suffix) {
                    finished.removeLast(suffix.count)
                }
                contextLanguage = contextAtWordStart
                restore(undo)
                let (nextPlain, nextMarked) = clientSplit()
                let field = replaceFinishedSuffix(suffix, withPlain: nextPlain, mark: nextMarked)
                plain = nextPlain
                preedit = nextMarked
                return make(field, marked: preedit, didAutoConvert: false)
            }
            restore(undo)
            return syncClient(didAutoConvert: false)
        }

        if !keys.isEmpty {
            let flipped = (segments.last?.lang ?? mode).flipped
            locked = flipped
            mode = flipped
            segments = [Segment(start: 0, end: keys.count, lang: flipped)]
            return syncClient(didAutoConvert: false)
        }

        mode = mode.flipped
        wordMode = mode
        locked = nil
        return make(.none, marked: preedit, didAutoConvert: false)
    }

    /// Hand the caret back to the app without rewriting characters. English
    /// is already inserted. Hangul, if any, is unmarked in place.
    public func commitDisplayed(endingRun: Bool = false) -> SessionUpdate {
        let hadToken = !keys.isEmpty
        noteRetype(final: render(segments))
        pendingUndo = nil
        let field: FieldEdit = preedit.isEmpty ? .none : .unmark(preedit)
        finished += plain + preedit
        clearToken()
        if endingRun || hadToken {
            contextLanguage = nil
        }
        return make(field, marked: "", didAutoConvert: false)
    }

    public func forceMode(_ language: Language) -> SessionUpdate {
        let update = commitDisplayed()
        mode = language
        wordMode = language
        locked = nil
        return SessionUpdate(mode: mode, didAutoConvert: false, preedit: "", field: update.field)
    }

    public func discard() -> SessionUpdate {
        rejected = nil
        contextLanguage = nil
        let field: FieldEdit = preedit.isEmpty ? .none : .mark("")
        finished += plain
        clearToken()
        pendingUndo = nil
        return make(field, marked: "", didAutoConvert: false)
    }

    public var debugLine: String {
        let description = segments.map { "\($0.lang.rawValue):\($0.start)-\($0.end)" }.joined(separator: " ")
        return "\(document) {\(description)} mode=\(mode.rawValue) lock=\(locked?.rawValue ?? "-") mark=\(preedit)"
    }

    private func finishWord(appending breaker: Character) -> SessionUpdate {
        let previous = segments
        let before = render(segments)
        _ = recompute(wordFinal: true, previous: previous.isEmpty ? nil : previous)
        let composedSegments = segments
        let composed = render(segments)
        noteRetype(final: composed)
        var word = composed
        if correctsTypos, locked == nil, let fixed = corrected(composed) {
            word = fixed
        }
        let suffix = word + String(breaker)
        if word != composed, !keys.isEmpty {
            pendingUndo = Undo(keys: keys, segments: composedSegments, committedSuffix: suffix)
        } else if composed != before, !keys.isEmpty {
            pendingUndo = Undo(keys: keys, segments: previous, committedSuffix: suffix)
        } else if let undo = pendingUndo, undo.committedSuffix == nil, undo.keys.count == keys.count, !keys.isEmpty {
            pendingUndo = Undo(keys: undo.keys, segments: undo.segments, committedSuffix: suffix)
        } else {
            pendingUndo = nil
        }
        let field = finishField(word: word, breaker: breaker)
        finished += suffix
        let sentence = isSentenceBoundary(breaker) || ".?!".contains(composed.last ?? " ")
        if sentence {
            contextLanguage = nil
        } else if !keys.isEmpty, let language = composedSegments.last?.lang {
            contextLanguage = language
        }
        let converted = composed != before && !before.isEmpty
        clearToken()
        return make(field, marked: "", didAutoConvert: converted)
    }

    /// A finished token whose spelling was not what the keys composed.
    private func corrected(_ composed: String) -> String? {
        guard segments.count == 1, let only = segments.first, only.start == 0, only.end == keys.count else { return nil }
        return TypoCorrector.correction(
            composed: composed,
            keys: keys,
            language: only.lang,
            lexicon: lexicon,
            memory: typos
        )
    }

    private func noteRetype(final: String) {
        let snapshot = rejected
        rejected = nil
        guard let snapshot else { return }
        let wrongKeys = String(snapshot.keys.map(\.english))
        let finalKeys = String(keys.map(\.english))
        guard TypoLogPolicy.shouldStore(wrong: snapshot.text, final: final, wrongKeys: wrongKeys, finalKeys: finalKeys) else { return }
        typos?.record(wrong: snapshot.text, wrongKeys: wrongKeys, final: final, finalKeys: finalKeys)
    }

    private func isSentenceBoundary(_ breaker: Character) -> Bool {
        ".\n?!".contains(breaker)
    }

    private func finishField(word: String, breaker: Character) -> FieldEdit {
        let suffix = word + String(breaker)
        let displayed = plain + preedit
        if word == displayed {
            if preedit.isEmpty {
                return .insert(String(breaker))
            }
            return .insert(preedit + String(breaker))
        }
        if preedit.isEmpty {
            return .insertReplacing(utf16: utf16Length(plain), text: suffix)
        }
        if plain.isEmpty || word.hasPrefix(plain) {
            let rest = plain.isEmpty ? word : String(word.dropFirst(plain.count))
            return .insert(rest + String(breaker))
        }
        let span = utf16Length(plain) + utf16Length(preedit)
        return .insertReplacing(utf16: span, text: suffix)
    }

    private func clearToken() {
        keys = []
        segments = []
        locked = nil
        plain = ""
        preedit = ""
        rejected = nil
    }

    private func restore(_ undo: Undo) {
        keys = undo.keys
        segments = undo.segments
        locked = undo.segments.last?.lang ?? mode
        mode = locked ?? mode
    }

    private func replaceFinishedSuffix(_ suffix: String, withPlain nextPlain: String, mark nextMarked: String) -> FieldEdit {
        let width = utf16Length(suffix)
        if nextMarked.isEmpty {
            return .insertReplacing(utf16: width, text: nextPlain)
        }
        if nextPlain.isEmpty {
            return .replaceBeforeCaret(utf16: width, text: nextMarked)
        }
        return .insertReplacingThenMark(utf16: width, insert: nextPlain, mark: nextMarked)
    }

    @discardableResult
    private func recompute(wordFinal: Bool, previous: [Segment]?) -> Bool {
        preferredUndo = nil
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

        // "Open" is 9펴 and "Int" is 8서: a shifted digit plus a syllable.
        // That shape must not outrank a capitalized English word. A pure
        // digit run (OK → 95) is excluded and stays a number.
        if prefersCapitalizedEnglish() {
            let english = [Segment(start: 0, end: keys.count, lang: .english)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(english) != render(extended)
            }
            segments = english
            mode = .english
            return changed
        }

        // "ktx는" is two legal syllables (걱는), so Hangul stickiness would
        // swallow the acronym. A short acronym plus a particle splits first.
        // "한은" stays Hangul: 한 starts a real dictionary word.
        if let headEnd = acronymParticleSplit() {
            let parts = [
                Segment(start: 0, end: headEnd, lang: .english),
                Segment(start: headEnd, end: keys.count, lang: .korean),
            ]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(parts) != render(extended)
            }
            segments = parts
            mode = .korean
            return changed
        }

        // "of" is the syllable 차. After an English word the short function
        // word stays English. Hangul stickiness still wins for every other buffer.
        if prefersContextualEnglish() {
            let english = [Segment(start: 0, end: keys.count, lang: .english)]
            let korean = [Segment(start: 0, end: keys.count, lang: .korean)]
            // The key before this one may already be Latin because the mode
            // followed the English word. Undo still has to bring back 차.
            if render(english) != render(korean) {
                preferredUndo = korean
            }
            var changed = preferredUndo != nil
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = changed || render(english) != render(extended)
            }
            segments = english
            mode = .english
            return changed
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

        // "N.M" is the digit keys for 0.1. A dot must not turn that into an
        // English token the way "agents.md" stays English.
        if prefersShiftedNumber() {
            let korean = [Segment(start: 0, end: keys.count, lang: .korean)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(korean) != render(extended)
            }
            segments = korean
            mode = .korean
            return changed
        }

        // ㄲ·ㄸ·ㅃ·ㅆ·ㅉ are one choseong typed with two keys. "ll" is also the
        // prefix of "llvm", so the pair must stay ㅉ and not become Latin.
        if prefersDoubledChoseong() {
            let korean = [Segment(start: 0, end: keys.count, lang: .korean)]
            var changed = false
            if let previous, let extended = extend(previous, to: keys.count) {
                changed = render(korean) != render(extended)
            }
            segments = korean
            mode = .korean
            return changed
        }

        // ㅎㅎ, ㅋㅋ, ㅠㅠ, ㄱㅅ. The first ㅠ is only the key "5", so the
        // mode flips, but the word was started in Korean.
        if prefersBareJamoRun(previous) {
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
            // One number-row key is a jamo ("2" is ㅆ). A run of them ("2024")
            // is a number. A syllable that merely contains ㅆ is not this case.
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

    /// Particles and short endings that attach to a word with no space.
    private static let particles = KoreanEndings.set

    /// Short words that are a real English word and also a Hangul reading.
    /// `of` is 차. Only the word before them, in the same run, picks a side.
    private static let englishContextWords: Set<String> = [
        "of", "to", "in", "is", "it", "on", "at", "as", "or", "if", "an",
        "be", "do", "go", "no", "so", "up", "we", "me", "my", "the",
    ]

    private func prefersContextualEnglish() -> Bool {
        guard contextLanguage == .english else { return false }
        guard (2...3).contains(keys.count) else { return false }
        let spelling = englishText(0..<keys.count)
        guard spelling.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
        guard Self.englishContextWords.contains(spelling), lexicon.isEnglishWord(spelling) else { return false }
        return true
    }

    /// Short heads that may keep a Hangul particle (`ktx는`, `api를`).
    /// A 3-letter Webster hit such as "jfk" is not enough: it steals the
    /// first ㄱ of 까.
    private static let acronymHeads: Set<String> = [
        "ktx", "srt", "api", "url", "mvp", "sdk", "llm", "gpt", "nlp",
        "cpu", "gpu", "html", "css", "aws",
    ]

    /// Index where an English acronym ends and a Hangul particle begins.
    /// Nil when the buffer should stay one language.
    private func acronymParticleSplit() -> Int? {
        guard wordMode == .korean, keys.count >= 4 else { return nil }
        let spelling = englishText(0..<keys.count).lowercased()
        // Still typing "backfall" or "hello". A particle-shaped tail is a coincidence.
        if lexicon.isEnglishWord(spelling) || lexicon.isEnglishPrefix(spelling) { return nil }
        let whole = Composer.compose(keys)
        // 아까, 아는, 뭔가, 쪽에서. A dictionary reading is never an acronym.
        if lexicon.isKoreanWord(whole.text) { return nil }
        let limit = min(6, keys.count - 1)
        guard limit >= 3 else { return nil }
        let wholeClean: Bool
        if case .clean = shape(of: whole.pieces) { wholeClean = true } else { wholeClean = false }
        for headEnd in 3...limit {
            let tail = Composer.compose(keys[headEnd..<keys.count])
            guard Self.particles.contains(tail.text) else { continue }
            guard case .clean = shape(of: tail.pieces) else { continue }
            let head = Composer.compose(keys[0..<headEnd])
            // 열 is "jew". The syllable itself is a Korean word.
            if lexicon.isKoreanWord(head.text) { continue }
            let listed = Self.acronymHeads.contains(englishText(0..<headEnd).lowercased())
            // Clean Hangul stays Korean. That includes a split which would
            // break ㄲ·ㄸ·ㅃ·ㅆ·ㅉ or a compound batchim: 아까 is not 아ㄱ+가.
            // Only an allowlisted acronym (ktx는) may still divide it.
            if wholeClean {
                guard listed else { continue }
            } else {
                guard strongAcronymHead(headEnd) else { continue }
            }
            return headEnd
        }
        return nil
    }

    /// Allowlisted acronym, or an English dictionary word of at least four
    /// letters. Used when the buffer is not itself clean Hangul (`github에`).
    private func strongAcronymHead(_ headEnd: Int) -> Bool {
        let head = keys[0..<headEnd]
        let spelling = englishText(0..<headEnd)
        guard (3...6).contains(spelling.count), spelling.allSatisfy(\.isLetter) else { return false }
        guard !head.allSatisfy(isPadDigit) else { return false }
        let lower = spelling.lowercased()
        if Self.acronymHeads.contains(lower) { return true }
        return spelling.count >= 4 && lexicon.isEnglishWord(lower)
    }

    /// ㄲ·ㄸ·ㅃ·ㅆ·ㅉ before the vowel. Two choseong keys, one jamo.
    private func prefersDoubledChoseong() -> Bool {
        guard wordMode == .korean, keys.count == 2 else { return false }
        guard case .jamo(let first) = keys[0].korean, case .jamo(let second) = keys[1].korean else { return false }
        guard first.kind == .choseong, second.kind == .choseong, Hangul.merge(first, second) != nil else { return false }
        return Composer.compose(keys).pieces == [.bareChoseong]
    }

    /// "Introduce" / "Open" / "Hello". The first shifted key is a digit or
    /// symbol on 390, and it is put back once the spelling is English.
    /// "OK" and "IO" are only digit keys, so they stay 95 and 89.
    private func prefersCapitalizedEnglish() -> Bool {
        let spelling = englishText(0..<keys.count)
        guard spelling.count >= 2, spelling.allSatisfy(\.isLetter) else { return false }
        guard keys.contains(where: isShiftedLetter) else { return false }
        guard !keys.allSatisfy(isPadDigit) else { return false }
        if lexicon.isAbbreviation(spelling) { return true }
        let lower = spelling.lowercased()
        return lexicon.isEnglishWord(lower) || lexicon.isEnglishPrefix(lower)
    }

    /// 0.1, 3.14, 1,000, 2026.10.23. The keys are shifted digits with '.'
    /// or ',' between them. "OK." stays an abbreviation: a trailing
    /// separator after a word is a period, not a decimal point.
    private func prefersShiftedNumber() -> Bool {
        guard !keys.isEmpty else { return false }
        var digits = 0
        var separators = 0
        for atom in keys {
            if isPadDigit(atom) {
                digits += 1
                continue
            }
            if atom.english == "." || atom.english == "," {
                separators += 1
                continue
            }
            return false
        }
        guard digits > 0, separators > 0 else { return false }
        if let last = keys.last, last.english == "." || last.english == "," {
            let body = keys.dropLast()
            let onlyTrailing = !body.contains { $0.english == "." || $0.english == "," }
            if onlyTrailing {
                let letters = String(body.map(\.english))
                let lower = letters.lowercased()
                if lexicon.isAbbreviation(letters) || lexicon.isEnglishWord(lower) || lexicon.isEnglishPrefix(lower) {
                    return false
                }
            }
        }
        return true
    }

    /// Repeated bare jamo in a word that was started in Korean: ㅎㅎ, ㅋㅋ,
    /// ㅠㅠ, ㅜㅜ, ㄱㅅ. An English word ("to", "know") and a prefix that was
    /// already Latin ("th") are left alone. ㄲ·ㄸ·ㅃ are one choseong, not
    /// this case.
    private func prefersBareJamoRun(_ previous: [Segment]?) -> Bool {
        guard wordMode == .korean else { return false }
        let composition = Composer.compose(keys)
        guard composition.pieces.count >= 2, composition.pieces.allSatisfy(isBarePiece) else { return false }
        let spelling = englishText(0..<keys.count)
        let lower = spelling.lowercased()
        // "src/" is a path. The slash key is also ㅗ, so the pieces are bare jamo.
        if spelling.contains(where: { CodeToken.interior.contains($0) }) { return false }
        if lexicon.isEnglishWord(lower) || lexicon.isCodeToken(spelling) || lexicon.isAbbreviation(spelling) {
            return false
        }
        if let previous, !previous.isEmpty, previous.allSatisfy({ $0.lang == .english }),
           lexicon.isEnglishPrefix(lower) || lexicon.isEnglishWord(lower) {
            return false
        }
        return true
    }

    private func isBarePiece(_ piece: CompositionPiece) -> Bool {
        switch piece {
        case .bareChoseong, .bareJungseong, .bareJongseong:
            return true
        case .syllable, .digit, .symbol:
            return false
        }
    }

    /// Shifted key whose 390 output is a digit or symbol, not a jamo.
    /// "I" is 8, "H" is "'", "P" is ">".
    private func isShiftedLetter(_ atom: KeyAtom) -> Bool {
        guard atom.english.isLetter, atom.english.isUppercase else { return false }
        if case .character = atom.korean { return true }
        return false
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
    /// dotted token ("agents.md", "a.b.c", "https://…") stays in that token.
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

    private func syncClient(didAutoConvert: Bool) -> SessionUpdate {
        let (nextPlain, nextMarked) = clientSplit()
        return emit(toPlain: nextPlain, toMarked: nextMarked, didAutoConvert: didAutoConvert)
    }

    /// English, digits, and symbols are inserted once. The trailing Hangul,
    /// including every composing segment of the current syllable, stays one
    /// marked range so the next key replaces that range instead of inserting
    /// the same characters again. Digits that share a segment with a syllable
    /// ("1개") stay inserted; only the syllable is marked.
    private func clientSplit() -> (plain: String, marked: String) {
        guard !segments.isEmpty else { return ("", "") }
        var splitAt = segments.count
        while splitAt > 0 {
            let segment = segments[splitAt - 1]
            if segment.lang == .korean, segmentComposes(segment) {
                splitAt -= 1
            } else {
                break
            }
        }
        let head = render(Array(segments[..<splitAt]))
        let tail = Array(segments[splitAt...])
        guard let first = tail.first else { return (head, "") }
        let peeled = peelDigitsAndSymbols(first)
        var marked = peeled.open
        if tail.count > 1 {
            marked += render(Array(tail.dropFirst()))
        }
        if marked.isEmpty {
            return (head + render(tail), "")
        }
        let stable = head + peeled.stable
        // The particle is already a finished syllable. Committing it in the
        // same replacement as the acronym avoids a second client call.
        if Self.particles.contains(marked), !stable.isEmpty, stable.unicodeScalars.allSatisfy(\.isASCII) {
            return (stable + marked, "")
        }
        return (stable, marked)
    }

    /// A 390 digit or symbol at the front of a Hangul segment was already
    /// inserted. Putting it inside the new marked text types it a second time.
    private func peelDigitsAndSymbols(_ segment: Segment) -> (stable: String, open: String) {
        let composition = Composer.compose(keys[segment.start..<segment.end])
        let chars = Array(composition.text)
        guard chars.count == composition.pieces.count else {
            return ("", composition.text)
        }
        var index = 0
        for piece in composition.pieces {
            switch piece {
            case .digit, .symbol:
                index += 1
            case .syllable, .bareChoseong, .bareJungseong, .bareJongseong:
                return (String(chars[..<index]), String(chars[index...]))
            }
        }
        return (composition.text, "")
    }

    private func segmentComposes(_ segment: Segment) -> Bool {
        let pieces = Composer.compose(keys[segment.start..<segment.end]).pieces
        return pieces.contains { piece in
            switch piece {
            case .syllable, .bareChoseong, .bareJungseong, .bareJongseong:
                return true
            case .digit, .symbol:
                return false
            }
        }
    }

    private func emit(toPlain: String, toMarked: String, didAutoConvert: Bool) -> SessionUpdate {
        var field = clientDiff(fromPlain: plain, fromMarked: preedit, toPlain: toPlain, toMarked: toMarked)
        var nextPlain = toPlain
        var nextMarked = toMarked
        // insertThenMark and a rewrite that also marks are two client calls.
        // The second call still sees the old caret and inserts the text again.
        if field.sendsMoreThanOneEdit, marksAfterInsert(field) {
            let span = utf16Length(plain) + utf16Length(preedit)
            let text = toPlain + toMarked
            field = .insertReplacing(utf16: span, text: text)
            nextPlain = text
            nextMarked = ""
        }
        plain = nextPlain
        preedit = nextMarked
        return make(field, marked: nextMarked, didAutoConvert: didAutoConvert)
    }

    private func marksAfterInsert(_ field: FieldEdit) -> Bool {
        switch field {
        case .insertThenMark, .insertReplacingThenMark:
            return true
        case .rewrite(_, _, let thenMark):
            return !thenMark.isEmpty
        default:
            return false
        }
    }

    private func clientDiff(fromPlain: String, fromMarked: String, toPlain: String, toMarked: String) -> FieldEdit {
        if fromPlain == toPlain, fromMarked == toMarked {
            return .none
        }
        if fromPlain == toPlain {
            return .mark(toMarked)
        }
        if fromMarked.isEmpty, toPlain.hasPrefix(fromPlain) {
            let delta = String(toPlain.dropFirst(fromPlain.count))
            if toMarked.isEmpty { return .insert(delta) }
            if delta.isEmpty { return .mark(toMarked) }
            return .insertThenMark(insert: delta, mark: toMarked)
        }
        if fromMarked.isEmpty, fromPlain.hasPrefix(toPlain) {
            let removed = utf16Length(String(fromPlain.dropFirst(toPlain.count)))
            if toMarked.isEmpty {
                return .insertReplacing(utf16: removed, text: "")
            }
            return .replaceBeforeCaret(utf16: removed, text: toMarked)
        }
        if toPlain.hasPrefix(fromPlain) {
            let delta = String(toPlain.dropFirst(fromPlain.count))
            if toMarked.isEmpty { return .insert(delta) }
            if delta.isEmpty { return .mark(toMarked) }
            return .insertThenMark(insert: delta, mark: toMarked)
        }
        if fromPlain.hasPrefix(toPlain) {
            let removed = utf16Length(String(fromPlain.dropFirst(toPlain.count)))
            if removed == 0 { return .mark(toMarked) }
            // One range covers the committed tail and the live mark. A second
            // call would still see the old caret and insert the tail again.
            let span = removed + utf16Length(fromMarked)
            if toMarked.isEmpty {
                return .insertReplacing(utf16: span, text: "")
            }
            return .replaceBeforeCaret(utf16: span, text: toMarked)
        }
        let span = utf16Length(fromPlain) + utf16Length(fromMarked)
        return .rewrite(utf16: span, text: toPlain, thenMark: toMarked)
    }

    private func make(_ field: FieldEdit, marked: String, didAutoConvert: Bool) -> SessionUpdate {
        SessionUpdate(mode: mode, didAutoConvert: didAutoConvert, preedit: marked, field: field)
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

private struct Rejection {
    var keys: [KeyAtom]
    var text: String
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
