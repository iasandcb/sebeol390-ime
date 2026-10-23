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
    #expect(session.preedit == "kf")
    #expect(session.mode == .english)
}

@Test func manualModeDoesNotConvert() {
    let session = Session(lexicon: lexicon, autoSwitch: false, mode: .korean)
    _ = session.type("hello")
    #expect(session.preedit != "hello")
    _ = session.commitDisplayed()
    _ = session.forceMode(.english)
    _ = session.type("hello")
    #expect(session.preedit == "hello")
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

private func assertTypes(_ keys: String, _ expected: String) {
    let session = Session(lexicon: lexicon, mode: .korean)
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

private extension Session {
    func type(_ text: String) -> String {
        for character in text {
            _ = input(character)
        }
        return document
    }
}
