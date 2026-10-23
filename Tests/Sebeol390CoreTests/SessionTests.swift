import Foundation
import Testing
@testable import Sebeol390Core

private let lexicon: Lexicon = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    return try! Lexicon.load(from: root)
}()

@Test func ibryeokStaysKorean() {
    // 력 is y e x, and "yex" is an English word. The syllable must not be stolen.
    assertTypes("jd3yex", "입력")
    assertTypes("jd3yex ", "입력 ")
    for word in ["입력", "모르다", "됐다"] {
        let keys = SebeolKeys.keys(for: word)!
        assertTypes(keys, word)
    }
}

@Test func agentsStayEnglish() {
    assertTypes("agents", "agents")
    assertTypes("agents ", "agents ")
    assertCodeTokens([
        "agents.md",
        "https://agents.md",
        "README.md",
        "build.sh",
        "package.json",
        "foo.com",
        "a.b.c",
        "user@host.com",
        "src/main.swift",
        "localhost:8080",
        "https://example.com/a/b",
        "foo-bar.txt",
        "my_file.txt",
        "v2.0.1",
        "c++",
    ])
    // A Hangul word still ends at a period, and the next word can be Korean.
    let gana = (SebeolKeys.keys(for: "가") ?? "") + "." + (SebeolKeys.keys(for: "나") ?? "")
    assertTypes(gana, "가.나")
    // ㅗ on the slash key is still a vowel, not a path separator.
    assertTypes("k/f", "과")
    assertTypes("kvf", "과")
    // A dot with no filename around it does not turn a bare syllable into Latin.
    assertTypes("md", "히")
}

@Test func koreanAfterAFileName() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.type("agents.md ")
    _ = session.type(SebeolKeys.keys(for: "입력")!)
    #expect(session.document == "agents.md 입력", "\(session.debugLine)")
}

@Test func englishSentenceThenKorean() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.type("hello.jfsheamfncj4")
    #expect(session.document == "hello.안녕하세요", "\(session.debugLine)")
}

@Test func commonEnglishWordsDoNotFlipMidWord() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    let dictionary = loadWordList(root.appendingPathComponent("english-words.txt"))
    let extra = loadWordList(root.appendingPathComponent("english-extra.txt"))
    var words: [String] = []
    var seen: Set<String> = []
    func add(_ word: String) {
        let key = word.lowercased()
        guard key.count >= 3, key.allSatisfy(\.isLetter), seen.insert(key).inserted else { return }
        words.append(key)
    }
    for word in extra { add(word) }
    for word in dictionary where (3...6).contains(word.count) { add(word) }
    for word in dictionary where (7...14).contains(word.count) && englishWordHidesHangulSyllable(word) {
        add(word)
    }
    var failures: [String] = []
    for word in words {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        var latin = false
        var failed = false
        for character in word {
            typed.append(character)
            _ = session.input(character)
            if sticksAsKorean(typed) {
                let korean = Composer.compose(typed.map { Layout390.atom(for: $0) }).text
                if session.document != korean {
                    failures.append("\(word) [\(typed)] 한글 \(session.document) / \(korean)")
                    failed = true
                    break
                }
                latin = false
                continue
            }
            let plausible = lexicon.isEnglishWord(typed) || lexicon.isEnglishPrefix(typed)
            if session.document == typed {
                latin = true
            } else if latin && plausible {
                failures.append("\(word) [\(typed)] → \(session.document)")
                failed = true
                break
            }
        }
        if !failed, session.document != word {
            let korean = Composer.compose(word.map { Layout390.atom(for: $0) }).text
            if session.document != korean {
                failures.append("끝 \(word) → \(session.document)")
            }
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func commonKoreanWordsStayKoreanThroughEveryKey() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-words.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.allSatisfy(isModernSyllable) && $0.count >= 2 }
    var failures: [String] = []
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("칠 수 없음 \(word)")
            continue
        }
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        for character in keys {
            typed.append(character)
            _ = session.input(character)
            let korean = Composer.compose(typed.map { Layout390.atom(for: $0) }).text
            if session.document != korean {
                failures.append("\(word) [\(typed)] → \(session.document) / \(korean)")
                break
            }
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func koreanSentencesStayKorean() {
    assertTypes("jfsheamfncj4", "안녕하세요")
    assertTypes("mfskgw", "한글")
    assertTypes("nc;twndx", "세벌식")
    assertTypes("mr2ng3hduf", "했습니다")
    assertTypes("mr2hgsuc", "했는데")
    assertTypes("mrnt", "해서")
}

@Test func loneJamoDoesNotReplaceEnglish() {
    // x and a are jongseong. They must stay letters, including after a Korean word.
    assertTypes("x ifs", "x 만")
    assertTypes("a ifs", "a 만")
    assertTypes("x ", "x ")
    assertTypes("a ", "a ")
    assertTypes("i ", "i ")
    assertTypes("k ", "k ")
    assertTypes("v2", "v2")
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    #expect(session.preedit == "ㄱ")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.input(" ")
    #expect(session.document == "가 ")
    let ex = session.input("x")
    #expect(ex.field == .insert("x"))
    #expect(session.preedit.isEmpty, "\(session.debugLine)")
    #expect(session.document == "가 x")
}

@Test func englishWordsStayEnglish() {
    assertTypes("deploy", "deploy")
    assertTypes("hello", "hello")
    assertTypes("other", "other")
    assertTypes("the", "the")
    assertTypes("to", "to")
    assertTypes("git", "git")
    assertTypes("push", "push")
    assertTypes("and", "and")
}

@Test func mixedWordsAndCodeTokens() {
    assertTypes("deploymr2hgsuc", "deploy했는데")
    assertTypes("AIyv", "AI로")
    assertTypes("build.sh", "build.sh")
    assertTypes("v2", "v2")
    assertTypes("git push", "git push")
    assertTypes("http", "http")
    assertTypes("don't", "don't")
}

@Test func undoRestoresReadingBeforeConversion() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("d")
    _ = session.input("e")
    #expect(session.document == "de")
    _ = session.toggle()
    #expect(session.preedit == "ㅣㅕ")
    _ = session.input("p")
    #expect(!session.document.contains("dep"), "\(session.debugLine)")
    #expect(session.mode == .korean)
}

@Test func toggleFlipsCurrentWordWhenNothingWasConverted() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.toggle()
    #expect(session.preedit.isEmpty)
    #expect(session.document == "kf")
    #expect(session.mode == .english)
}

@Test func manualModeDoesNotConvert() {
    let session = Session(lexicon: lexicon, autoSwitch: false, mode: .korean)
    _ = session.type("hello")
    #expect(session.preedit != "hello")
    _ = session.commitDisplayed()
    _ = session.forceMode(.english)
    _ = session.type("hello")
    #expect(session.preedit.isEmpty)
    #expect(session.document.hasSuffix("hello"))
}

@Test func backspaceRemovesLastJamo() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.backspace()
    #expect(session.preedit == "ㄱ")
    _ = session.backspace()
    #expect(session.preedit == "")
}

@Test func englishIsInsertedAndNavigationDoesNotRewriteIt() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    let typed = session.input("x")
    paper.apply(typed.field)
    #expect(typed.field == .insert("x"))
    #expect(session.preedit.isEmpty)
    #expect(paper.text == "x")
    #expect(paper.marked.isEmpty)

    let before = session.document
    let down = session.commitDisplayed()
    paper.apply(down.field)
    #expect(down.field.preservesCharacters)
    #expect(down.field == .none)
    #expect(session.document == before)
    #expect(paper.text == before)

    let english = Session(lexicon: lexicon, autoSwitch: false, mode: .english)
    var englishPaper = Paper()
    for character in "hello" {
        let update = english.input(character)
        englishPaper.apply(update.field)
        #expect(english.preedit.isEmpty, "\(english.debugLine)")
        #expect(update.field == .insert(String(character)))
        #expect(englishPaper.marked.isEmpty)
    }
    #expect(english.document == "hello")
    let tab = english.commitDisplayed()
    #expect(tab.field == .none)
    #expect(english.document == "hello")

    let deploy = Session(lexicon: lexicon, mode: .korean)
    var deployPaper = Paper()
    for character in "deploy" {
        let update = deploy.input(character)
        deployPaper.apply(update.field)
        #expect(deploy.preedit.isEmpty, "\(deploy.debugLine)")
        #expect(deployPaper.marked.isEmpty)
    }
    #expect(deploy.document == "deploy")
    let arrow = deploy.commitDisplayed()
    #expect(arrow.field == .none)
    #expect(deploy.document == "deploy")

    let letter = Session(lexicon: lexicon, mode: .english)
    let eye = letter.input("I")
    #expect(eye.field == .insert("I"))
    #expect(letter.preedit.isEmpty)
    let escaped = letter.commitDisplayed()
    #expect(escaped.field == .none)
    #expect(letter.document == "I")
}

@Test func navigationLeavesHangulCharactersInPlace() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    paper.apply(session.input("k").field)
    paper.apply(session.input("f").field)
    #expect(session.preedit == "가")
    #expect(paper.text == "가")
    #expect(paper.marked == "가")
    let arrow = session.commitDisplayed()
    paper.apply(arrow.field)
    #expect(arrow.field == .unmark("가"))
    #expect(arrow.field.preservesCharacters)
    #expect(session.document == "가")
    #expect(session.preedit.isEmpty)
    #expect(paper.text == "가")
    #expect(paper.marked.isEmpty)
}

@Test func backspaceOfCommittedEnglishPassesThrough() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    paper.apply(session.input("x").field)
    let deleted = session.backspace()
    #expect(deleted.field == .none)
    paper.deleteOne()
    #expect(session.document.isEmpty)
    #expect(paper.text.isEmpty)

    paper.apply(session.input("v").field)
    paper.apply(session.input("2").field)
    #expect(session.preedit.isEmpty)
    #expect(session.document == "v2")
    #expect(paper.text == "v2")
    #expect(paper.marked.isEmpty)
}

@Test func fieldEditsMatchTheDocument() {
    let samples = [
        "x ifs",
        "a ifs",
        "x ",
        "k ",
        "i ",
        "v2",
        "jd3yex",
        "deploymr2hgsuc",
        "AIyv",
        "agents.md",
        "https://agents.md",
        "build.sh",
        "MN",
        "<N<L",
        "hello",
        "other",
        "git push",
        "don't",
        "MNkr",
        "k/f",
        "kvf",
    ]
    var failures: [String] = []
    for sample in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        var typed = ""
        for character in sample {
            typed.append(character)
            let update = session.input(character)
            paper.apply(update.field)
            if paper.text != session.document || paper.marked != session.preedit {
                failures.append("\(sample) [\(typed)] paper=\(paper.text) mark=\(paper.marked) doc=\(session.document) pre=\(session.preedit) \(update.field)")
                break
            }
        }
        let stopped = session.commitDisplayed()
        paper.apply(stopped.field)
        if stopped.field.preservesCharacters == false || paper.text != session.document {
            failures.append("멈춤 \(sample) \(stopped.field) paper=\(paper.text) doc=\(session.document)")
        }
        if session.preedit.isEmpty == false || paper.marked.isEmpty == false {
            failures.append("조합 남음 \(sample) \(session.preedit)")
        }
    }
    let english = Session(lexicon: lexicon, mode: .english)
    var paper = Paper()
    for character in "TV API MN" {
        let update = english.input(character)
        paper.apply(update.field)
        if paper.marked.isEmpty == false || paper.text != english.document {
            failures.append("영문 \(paper.text) \(english.document)")
            break
        }
    }
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func shortcutsAndSecureInputPassThrough() {
    #expect(InputGate.shouldPassThrough(secureInput: true, command: false, control: false, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: true, control: false, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: false, control: true, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: false, control: false, option: true))
    #expect(!InputGate.shouldPassThrough(secureInput: false, command: false, control: false, option: false))
}

private func assertCodeTokens(_ samples: [String]) {
    var failures: [String] = []
    let joiners: Set<Character> = [".", ":", "/", "@", "_", "-", "+", "?", "=", "&", "%", "#"]
    for sample in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        var sawJoiner = false
        for character in sample {
            typed.append(character)
            _ = session.input(character)
            if joiners.contains(character) { sawJoiner = true }
            if sawJoiner, session.document != typed {
                failures.append("\(sample) [\(typed)] → \(session.document)")
                break
            }
        }
        if !failures.contains(where: { $0.hasPrefix(sample) }), session.document != sample {
            failures.append("\(sample) → \(session.document)")
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

private func loadWordList(_ url: URL) -> [String] {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(whereSeparator: \.isNewline).map {
        String($0).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// "age" + "nts": a real English stem whose next three keys are one syllable.
private func englishWordHidesHangulSyllable(_ word: String) -> Bool {
    let chars = Array(word)
    guard chars.count >= 6 else { return false }
    for start in 3..<(chars.count - 2) {
        let stem = String(chars[..<start])
        guard lexicon.isEnglishWord(stem) else { continue }
        let tail = String(chars[start..<start + 3])
        if cleanSyllables(tail) == 1 { return true }
    }
    return false
}

private func cleanSyllables(_ text: String) -> Int {
    let pieces = Composer.compose(text.map { Layout390.atom(for: $0) }).pieces
    guard !pieces.isEmpty, pieces.allSatisfy({ $0 == .syllable }) else { return 0 }
    return pieces.count
}

private func sticksAsKorean(_ text: String) -> Bool {
    let pieces = Composer.compose(text.map { Layout390.atom(for: $0) }).pieces
    guard !pieces.isEmpty else { return false }
    var body = pieces
    if body.last == .bareChoseong { body.removeLast() }
    guard body.contains(.syllable) else { return false }
    return body.allSatisfy { $0 == .syllable || $0 == .digit }
}

@Test func padDigitsStayDigitsInKoreanMode() {
    let pad = ["M": "1", "N": "0", "U": "7", "I": "8", "O": "9", "J": "4", "K": "5", "L": "6", "<": "2", ">": "3"]
    var failures: [String] = []
    for (key, digit) in pad {
        let session = Session(lexicon: lexicon, mode: .korean)
        _ = session.input(key.first!)
        if session.document != digit {
            failures.append("\(key) → \(session.document)")
        }
    }
    for (left, leftDigit) in pad {
        for (right, rightDigit) in pad {
            let keys = left + right
            let session = Session(lexicon: lexicon, mode: .korean)
            for character in keys {
                _ = session.input(character)
            }
            let expected = leftDigit + rightDigit
            if session.document != expected {
                failures.append("\(keys) → \(session.document) / \(expected)")
            }
        }
    }
    let samples = [
        "M": "1",
        "MN": "10",
        "MNN": "100",
        "<N<L": "2026",
        ">.MJ": "3.14",
        "MN%": "10%",
        "MNkr": "10개",
        "<N<Lhes MNjbtw <>jdw": "2026년 10월 23일",
        "IO": "89",
        "OK": "95",
        "UI": "78",
        "ML": "16",
    ]
    for (keys, expected) in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        for character in keys {
            typed.append(character)
            _ = session.input(character)
            if session.document.contains(where: \.isUppercase) {
                failures.append("대문자 \(typed) → \(session.document)")
                break
            }
        }
        if session.document != expected {
            failures.append("\(keys) → \(session.document) / \(expected)")
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func englishModeKeepsAllCaps() {
    assertTypes("MN", "MN", mode: .english)
    assertTypes("API", "API", mode: .english)
    assertTypes("TV", "TV", mode: .english)
    assertTypes("OK", "OK", mode: .english)
    assertTypes("TV", "TV")
}

private func assertTypes(_ keys: String, _ expected: String, mode: Language = .korean) {
    let session = Session(lexicon: lexicon, mode: mode)
    var trace: [String] = []
    for character in keys {
        _ = session.input(character)
        trace.append(session.debugLine)
    }
    #expect(session.document == expected, "\(trace.joined(separator: "\n"))")
}

private func isModernSyllable(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
    return (0xAC00...0xD7A3).contains(scalar.value)
}

/// 390 keystrokes for a Hangul word. A letter key wins over a digit that
/// produces the same jamo, so the sweep hits the English-looking readings.
private enum SebeolKeys {
    static func keys(for word: String) -> String? {
        var result = ""
        for character in word {
            guard let part = keys(for: character) else { return nil }
            result += part
        }
        return result
    }

    static func keys(for syllable: Character) -> String? {
        guard let scalar = syllable.unicodeScalars.first else { return nil }
        let code = Int(scalar.value - 0xAC00)
        let cho = UInt32(0x1100 + code / 588)
        let jung = UInt32(0x1161 + (code % 588) / 28)
        let jongIndex = code % 28
        guard let choKeys = sequence(.choseong, cho), let jungKeys = sequence(.jungseong, jung) else { return nil }
        var text = choKeys + jungKeys
        if jongIndex != 0 {
            guard let jongKeys = sequence(.jongseong, UInt32(0x11A8 + jongIndex - 1)) else { return nil }
            text += jongKeys
        }
        return text
    }

    private static let byJamo: [Jamo: Character] = {
        let probe = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?")
        var map: [Jamo: Character] = [:]
        for character in probe {
            if case .jamo(let jamo) = Layout390.atom(for: character).korean, map[jamo] == nil {
                map[jamo] = character
            }
        }
        return map
    }()

    private static func sequence(_ kind: JamoKind, _ scalar: UInt32) -> String? {
        let target = Jamo(scalar: scalar, kind: kind)
        if let key = byJamo[target] { return String(key) }
        for (first, firstKey) in byJamo where first.kind == kind {
            for (second, secondKey) in byJamo where second.kind == kind {
                if Hangul.merge(first, second) == target {
                    return String(firstKey) + String(secondKey)
                }
            }
        }
        return nil
    }
}

/// Mirrors InputController.apply so tests can see what the field would show.
private struct Paper {
    var committed = ""
    var marked = ""
    var text: String { committed + marked }

    mutating func apply(_ field: FieldEdit) {
        switch field {
        case .none:
            break
        case .unmark(let string):
            committed += string
            marked = ""
        case .insert(let string):
            committed += string
            marked = ""
        case .mark(let string):
            marked = string
        case .replaceBeforeCaret(let utf16, let string):
            committed = dropEnd(committed, utf16)
            marked = string
        case .insertThenMark(let insert, let mark):
            committed += insert
            marked = mark
        case .insertReplacing(let utf16, let string):
            committed = dropEnd(committed, utf16) + string
            marked = ""
        case .insertReplacingThenMark(let utf16, let insert, let mark):
            committed = dropEnd(committed, utf16) + insert
            marked = mark
        case .clearMarkThenInsert(let utf16, let string):
            marked = ""
            committed = dropEnd(committed, utf16) + string
        case .clearMarkThenMark(let utf16, let string):
            marked = ""
            committed = dropEnd(committed, utf16)
            marked = string
        case .rewrite(let utf16, let string, let thenMark):
            var left = utf16
            let markUnits = utf16Count(marked)
            if left > 0 {
                let take = min(left, markUnits)
                marked = dropEnd(marked, take)
                left -= take
            }
            if left > 0 {
                committed = dropEnd(committed, left)
            }
            committed += string
            marked = thenMark
        }
    }

    mutating func deleteOne() {
        if marked.isEmpty {
            committed = dropEnd(committed, 1)
        } else {
            marked = dropEnd(marked, 1)
        }
    }
}

private func utf16Count(_ text: String) -> Int {
    (text as NSString).length
}

private func dropEnd(_ text: String, _ utf16: Int) -> String {
    let ns = text as NSString
    return ns.substring(to: max(0, ns.length - utf16))
}

private extension Session {
    func type(_ text: String) -> String {
        for character in text {
            _ = input(character)
        }
        return document
    }
}
