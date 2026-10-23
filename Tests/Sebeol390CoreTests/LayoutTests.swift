import Testing
@testable import Sebeol390Core

@Test func choseongKeys() {
    expectJamo("k", .choseong, "ㄱ")
    expectJamo("u", .choseong, "ㄷ")
    expectJamo("j", .choseong, "ㅇ")
    expectJamo("l", .choseong, "ㅈ")
    expectJamo("y", .choseong, "ㄹ")
    expectJamo("h", .choseong, "ㄴ")
    expectJamo("i", .choseong, "ㅁ")
    expectJamo(";", .choseong, "ㅂ")
    expectJamo("n", .choseong, "ㅅ")
    expectJamo("o", .choseong, "ㅊ")
    expectJamo("0", .choseong, "ㅋ")
    expectJamo("'", .choseong, "ㅌ")
    expectJamo("p", .choseong, "ㅍ")
    expectJamo("m", .choseong, "ㅎ")
}

@Test func jungseongKeys() {
    expectJamo("f", .jungseong, "ㅏ")
    expectJamo("r", .jungseong, "ㅐ")
    expectJamo("6", .jungseong, "ㅑ")
    expectJamo("R", .jungseong, "ㅒ")
    expectJamo("t", .jungseong, "ㅓ")
    expectJamo("e", .jungseong, "ㅕ")
    expectJamo("c", .jungseong, "ㅔ")
    expectJamo("7", .jungseong, "ㅖ")
    expectJamo("v", .jungseong, "ㅗ")
    expectJamo("/", .jungseong, "ㅗ")
    expectJamo("4", .jungseong, "ㅛ")
    expectJamo("b", .jungseong, "ㅜ")
    expectJamo("9", .jungseong, "ㅜ")
    expectJamo("5", .jungseong, "ㅠ")
    expectJamo("g", .jungseong, "ㅡ")
    expectJamo("8", .jungseong, "ㅢ")
    expectJamo("d", .jungseong, "ㅣ")
}

@Test func jongseongKeys() {
    expectJamo("x", .jongseong, "ㄱ")
    expectJamo("F", .jongseong, "ㄲ")
    expectJamo("s", .jongseong, "ㄴ")
    expectJamo("S", .jongseong, "ㄶ")
    expectJamo("A", .jongseong, "ㄷ")
    expectJamo("w", .jongseong, "ㄹ")
    expectJamo("D", .jongseong, "ㄺ")
    expectJamo("C", .jongseong, "ㄻ")
    expectJamo("V", .jongseong, "ㅀ")
    expectJamo("z", .jongseong, "ㅁ")
    expectJamo("3", .jongseong, "ㅂ")
    expectJamo("X", .jongseong, "ㅄ")
    expectJamo("q", .jongseong, "ㅅ")
    expectJamo("2", .jongseong, "ㅆ")
    expectJamo("a", .jongseong, "ㅇ")
    expectJamo("!", .jongseong, "ㅈ")
    expectJamo("Z", .jongseong, "ㅊ")
    expectJamo("E", .jongseong, "ㅋ")
    expectJamo("W", .jongseong, "ㅌ")
    expectJamo("Q", .jongseong, "ㅍ")
    expectJamo("1", .jongseong, "ㅎ")
}

@Test func sixRelocatedSymbols() {
    expectChar("B", "!")
    expectChar("G", "/")
    expectChar("T", ";")
    expectChar("Y", "<")
    expectChar("P", ">")
    expectChar("H", "'")
    expectJamo("!", .jongseong, "ㅈ")
    expectJamo("/", .jungseong, "ㅗ")
    expectJamo(";", .choseong, "ㅂ")
    expectChar("<", "2")
    expectChar(">", "3")
    expectJamo("'", .choseong, "ㅌ")
}

@Test func shiftedDigits() {
    let digits = [
        ("U", "7"), ("I", "8"), ("O", "9"),
        ("J", "4"), ("K", "5"), ("L", "6"),
        ("M", "1"), ("<", "2"), (">", "3"),
        ("N", "0"),
    ]
    for (key, digit) in digits {
        expectChar(Character(key), Character(digit))
    }
}

@Test func unchangedPunctuation() {
    for character in Array("`-=[]\\,.") + Array("~@#$%^&*()_+{}|:\"?") {
        expectChar(character, character)
    }
    expectChar(" ", " ")
}

@Test func everyLetterIsMapped() {
    for letter in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" {
        #expect(Layout390.contains(letter), "missing \(letter)")
    }
}

@Test func keymapMatchesQWERTYPositions() {
    #expect(Keymap.qwertyCharacter(keyCode: 0x00, shift: false) == "a")
    #expect(Keymap.qwertyCharacter(keyCode: 0x00, shift: true) == "A")
    #expect(Keymap.qwertyCharacter(keyCode: 0x0C, shift: false) == "q")
    #expect(Keymap.qwertyCharacter(keyCode: 0x12, shift: true) == "!")
    #expect(Keymap.qwertyCharacter(keyCode: 0x2C, shift: false) == "/")
    #expect(Keymap.qwertyCharacter(keyCode: 0x2B, shift: true) == "<")
    #expect(Keymap.qwertyCharacter(keyCode: 0x31, shift: false) == " ")
    #expect(Keymap.qwertyCharacter(keyCode: 0x17, shift: false) == "5")
    #expect(Keymap.qwertyCharacter(keyCode: 0x17, shift: true) == "%")
    #expect(Keymap.isNavigation(0x7D))
    #expect(Keymap.isNavigation(0x7B))
    #expect(Keymap.isNavigation(0x7C))
    #expect(Keymap.isNavigation(0x7E))
    #expect(Keymap.isNavigation(Keymap.tab))
    #expect(Keymap.isNavigation(Keymap.escape))
    #expect(Keymap.isNavigation(Keymap.return))
    #expect(!Keymap.isNavigation(0x07))
}

private func expectJamo(_ key: Character, _ kind: JamoKind, _ compat: Character) {
    let output = Layout390.atom(for: key).korean
    guard case .jamo(let jamo) = output else {
        Issue.record("\(key) produced \(output)")
        return
    }
    #expect(jamo.kind == kind, "\(key)")
    #expect(jamo.compat == compat, "\(key)")
}

private func expectChar(_ key: Character, _ expected: Character) {
    let output = Layout390.atom(for: key).korean
    guard case .character(let character) = output else {
        Issue.record("\(key) produced \(output)")
        return
    }
    #expect(character == expected, "\(key)")
}
