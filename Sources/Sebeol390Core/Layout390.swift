import Foundation

public enum KeyOutput: Equatable, Sendable {
    case jamo(Jamo)
    case character(Character)
}

public struct KeyAtom: Equatable, Sendable {
    public var english: Character
    public var korean: KeyOutput

    public var isNeutralBreaker: Bool {
        guard case .character(let koreanChar) = korean, koreanChar == english else { return false }
        if koreanChar.isLetter || koreanChar.isNumber { return false }
        return true
    }
}

/// 한글문화원 IBM-3-90 (1990), the layout macOS calls 세벌식 390.
///
/// Choseong sits on the right, jungseong and jongseong on the left. Digits on
/// the number row are jamo; the digits 0–9 themselves sit on the shifted
/// right-hand "keypad" (7 8 9 / 4 5 6 / 1 2 3 / 0). Six symbols move off the
/// QWERTY positions: ! / ; < > '
public enum Layout390 {
    public static func atom(for english: Character) -> KeyAtom {
        let korean = table[english] ?? .character(english)
        return KeyAtom(english: english, korean: korean)
    }

    public static func contains(_ english: Character) -> Bool {
        table[english] != nil
    }

    private static let table: [Character: KeyOutput] = {
        func j(_ jamo: Jamo) -> KeyOutput { .jamo(jamo) }
        func c(_ ch: Character) -> KeyOutput { .character(ch) }
        return [
            "`": c("`"),
            "1": j(.jong(0x11C2)), // ㅎ
            "2": j(.jong(0x11BB)), // ㅆ
            "3": j(.jong(0x11B8)), // ㅂ
            "4": j(.jung(0x116D)), // ㅛ
            "5": j(.jung(0x1172)), // ㅠ
            "6": j(.jung(0x1163)), // ㅑ
            "7": j(.jung(0x1168)), // ㅖ
            "8": j(.jung(0x1174)), // ㅢ
            "9": j(.jung(0x116E)), // ㅜ
            "0": j(.cho(0x110F)), // ㅋ
            "-": c("-"),
            "=": c("="),

            "q": j(.jong(0x11BA)), // ㅅ
            "w": j(.jong(0x11AF)), // ㄹ
            "e": j(.jung(0x1167)), // ㅕ
            "r": j(.jung(0x1162)), // ㅐ
            "t": j(.jung(0x1165)), // ㅓ
            "y": j(.cho(0x1105)), // ㄹ
            "u": j(.cho(0x1103)), // ㄷ
            "i": j(.cho(0x1106)), // ㅁ
            "o": j(.cho(0x110E)), // ㅊ
            "p": j(.cho(0x1111)), // ㅍ
            "[": c("["),
            "]": c("]"),
            "\\": c("\\"),

            "a": j(.jong(0x11BC)), // ㅇ
            "s": j(.jong(0x11AB)), // ㄴ
            "d": j(.jung(0x1175)), // ㅣ
            "f": j(.jung(0x1161)), // ㅏ
            "g": j(.jung(0x1173)), // ㅡ
            "h": j(.cho(0x1102)), // ㄴ
            "j": j(.cho(0x110B)), // ㅇ
            "k": j(.cho(0x1100)), // ㄱ
            "l": j(.cho(0x110C)), // ㅈ
            ";": j(.cho(0x1107)), // ㅂ
            "'": j(.cho(0x1110)), // ㅌ

            "z": j(.jong(0x11B7)), // ㅁ
            "x": j(.jong(0x11A8)), // ㄱ
            "c": j(.jung(0x1166)), // ㅔ
            "v": j(.jung(0x1169)), // ㅗ
            "b": j(.jung(0x116E)), // ㅜ
            "n": j(.cho(0x1109)), // ㅅ
            "m": j(.cho(0x1112)), // ㅎ
            ",": c(","),
            ".": c("."),
            "/": j(.jung(0x1169)), // ㅗ

            "~": c("~"),
            "!": j(.jong(0x11BD)), // ㅈ
            "@": c("@"),
            "#": c("#"),
            "$": c("$"),
            "%": c("%"),
            "^": c("^"),
            "&": c("&"),
            "*": c("*"),
            "(": c("("),
            ")": c(")"),
            "_": c("_"),
            "+": c("+"),

            "Q": j(.jong(0x11C1)), // ㅍ
            "W": j(.jong(0x11C0)), // ㅌ
            "E": j(.jong(0x11BF)), // ㅋ
            "R": j(.jung(0x1164)), // ㅒ
            "T": c(";"),
            "Y": c("<"),
            "U": c("7"),
            "I": c("8"),
            "O": c("9"),
            "P": c(">"),
            "{": c("{"),
            "}": c("}"),
            "|": c("|"),

            "A": j(.jong(0x11AE)), // ㄷ
            "S": j(.jong(0x11AD)), // ㄶ
            "D": j(.jong(0x11B0)), // ㄺ
            "F": j(.jong(0x11A9)), // ㄲ
            "G": c("/"),
            "H": c("'"),
            "J": c("4"),
            "K": c("5"),
            "L": c("6"),
            ":": c(":"),
            "\"": c("\""),

            "Z": j(.jong(0x11BE)), // ㅊ
            "X": j(.jong(0x11B9)), // ㅄ
            "C": j(.jong(0x11B1)), // ㄻ
            "V": j(.jong(0x11B6)), // ㅀ
            "B": c("!"),
            "N": c("0"),
            "M": c("1"),
            "<": c("2"),
            ">": c("3"),
            "?": c("?"),
            " ": c(" "),
        ]
    }()
}
