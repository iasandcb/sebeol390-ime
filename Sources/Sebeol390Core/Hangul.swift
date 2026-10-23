import Foundation

public enum JamoKind: Equatable, Sendable {
    case choseong
    case jungseong
    case jongseong
}

public struct Jamo: Equatable, Hashable, Sendable {
    public var scalar: UInt32
    public var kind: JamoKind

    public init(scalar: UInt32, kind: JamoKind) {
        self.scalar = scalar
        self.kind = kind
    }

    public static func cho(_ scalar: UInt32) -> Jamo { Jamo(scalar: scalar, kind: .choseong) }
    public static func jung(_ scalar: UInt32) -> Jamo { Jamo(scalar: scalar, kind: .jungseong) }
    public static func jong(_ scalar: UInt32) -> Jamo { Jamo(scalar: scalar, kind: .jongseong) }

    /// Compatibility jamo (U+3130 block) so an unfinished syllable is visible.
    /// The compatibility block inserts ㄳ·ㄵ·ㄶ·ㄺ… and ㄸ·ㅃ·ㅉ, so neither
    /// choseong nor jongseong is a constant offset from U+3131.
    public var compat: Character {
        let value: UInt32
        switch kind {
        case .choseong:
            value = Self.choCompat[scalar] ?? 0x3131
        case .jungseong:
            value = 0x314F + (scalar - 0x1161)
        case .jongseong:
            value = Self.jongCompat[scalar] ?? 0x3131
        }
        return Character(UnicodeScalar(value)!)
    }

    private static let choCompat: [UInt32: UInt32] = [
        0x1100: 0x3131, 0x1101: 0x3132, 0x1102: 0x3134, 0x1103: 0x3137,
        0x1104: 0x3138, 0x1105: 0x3139, 0x1106: 0x3141, 0x1107: 0x3142,
        0x1108: 0x3143, 0x1109: 0x3145, 0x110A: 0x3146, 0x110B: 0x3147,
        0x110C: 0x3148, 0x110D: 0x3149, 0x110E: 0x314A, 0x110F: 0x314B,
        0x1110: 0x314C, 0x1111: 0x314D, 0x1112: 0x314E,
    ]

    private static let jongCompat: [UInt32: UInt32] = [
        0x11A8: 0x3131, 0x11A9: 0x3132, 0x11AA: 0x3133, 0x11AB: 0x3134,
        0x11AC: 0x3135, 0x11AD: 0x3136, 0x11AE: 0x3137, 0x11AF: 0x3139,
        0x11B0: 0x313A, 0x11B1: 0x313B, 0x11B2: 0x313C, 0x11B3: 0x313D,
        0x11B4: 0x313E, 0x11B5: 0x313F, 0x11B6: 0x3140, 0x11B7: 0x3141,
        0x11B8: 0x3142, 0x11B9: 0x3144, 0x11BA: 0x3145, 0x11BB: 0x3146,
        0x11BC: 0x3147, 0x11BD: 0x3148, 0x11BE: 0x314A, 0x11BF: 0x314B,
        0x11C0: 0x314C, 0x11C1: 0x314D, 0x11C2: 0x314E,
    ]
}

public enum Hangul {
    /// Modern syllable composition. Same-class pairs only (세벌식 does not
    /// turn two choseong into a jongseong).
    public static func merge(_ first: Jamo, _ second: Jamo) -> Jamo? {
        guard first.kind == second.kind else { return nil }
        let key = (UInt64(first.scalar) << 32) | UInt64(second.scalar)
        guard let result = merges[key] else { return nil }
        return Jamo(scalar: result, kind: first.kind)
    }

    public static func syllable(cho: UInt32, jung: UInt32, jong: UInt32?) -> Character {
        let ci = Int(cho - 0x1100)
        let vi = Int(jung - 0x1161)
        let ti = jong.map { Int($0 - 0x11A8) + 1 } ?? 0
        let code = 0xAC00 + (ci * 21 + vi) * 28 + ti
        return Character(UnicodeScalar(code)!)
    }

    private static let merges: [UInt64: UInt32] = {
        var table: [UInt64: UInt32] = [:]
        let pairs: [(UInt32, UInt32, UInt32)] = [
            // Choseong doubles.
            (0x1100, 0x1100, 0x1101), // ㄱㄱ=ㄲ
            (0x1103, 0x1103, 0x1104), // ㄷㄷ=ㄸ
            (0x1107, 0x1107, 0x1108), // ㅂㅂ=ㅃ
            (0x1109, 0x1109, 0x110A), // ㅅㅅ=ㅆ
            (0x110C, 0x110C, 0x110D), // ㅈㅈ=ㅉ
            // Compound vowels.
            (0x1169, 0x1161, 0x116A), // ㅗㅏ=ㅘ
            (0x1169, 0x1162, 0x116B), // ㅗㅐ=ㅙ
            (0x1169, 0x1175, 0x116C), // ㅗㅣ=ㅚ
            (0x116E, 0x1165, 0x116F), // ㅜㅓ=ㅝ
            (0x116E, 0x1166, 0x1170), // ㅜㅔ=ㅞ
            (0x116E, 0x1175, 0x1171), // ㅜㅣ=ㅟ
            (0x1173, 0x1175, 0x1174), // ㅡㅣ=ㅢ
            // Compound batchim.
            (0x11A8, 0x11A8, 0x11A9), // ㄱㄱ=ㄲ
            (0x11A8, 0x11BA, 0x11AA), // ㄱㅅ=ㄳ
            (0x11AB, 0x11BD, 0x11AC), // ㄴㅈ=ㄵ
            (0x11AB, 0x11C2, 0x11AD), // ㄴㅎ=ㄶ
            (0x11AF, 0x11A8, 0x11B0), // ㄹㄱ=ㄺ
            (0x11AF, 0x11B7, 0x11B1), // ㄹㅁ=ㄻ
            (0x11AF, 0x11B8, 0x11B2), // ㄹㅂ=ㄼ
            (0x11AF, 0x11BA, 0x11B3), // ㄹㅅ=ㄽ
            (0x11AF, 0x11C0, 0x11B4), // ㄹㅌ=ㄾ
            (0x11AF, 0x11C1, 0x11B5), // ㄹㅍ=ㄿ
            (0x11AF, 0x11C2, 0x11B6), // ㄹㅎ=ㅀ
            (0x11B8, 0x11BA, 0x11B9), // ㅂㅅ=ㅄ
            (0x11BA, 0x11BA, 0x11BB), // ㅅㅅ=ㅆ
        ]
        for (a, b, c) in pairs {
            table[(UInt64(a) << 32) | UInt64(b)] = c
        }
        return table
    }()
}
