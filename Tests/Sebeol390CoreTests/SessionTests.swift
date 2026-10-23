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
