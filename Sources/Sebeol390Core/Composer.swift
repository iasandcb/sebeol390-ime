import Foundation

public enum CompositionPiece: Equatable, Sendable {
    case syllable
    case bareChoseong
    case bareJungseong
    case bareJongseong
    case digit
    case symbol
}

public struct Composition: Equatable, Sendable {
    public var text: String
    public var pieces: [CompositionPiece]

    public var syllableCount: Int {
        pieces.reduce(0) { $0 + ($1 == .syllable ? 1 : 0) }
    }
}

public enum Composer {
    public static func compose<S: Sequence>(_ atoms: S) -> Composition where S.Element == KeyAtom {
        var engine = Engine()
        for atom in atoms {
            switch atom.korean {
            case .jamo(let jamo):
                engine.push(jamo)
            case .character(let character):
                engine.pushCharacter(character)
            }
        }
        engine.flush()
        return Composition(text: engine.text, pieces: engine.pieces)
    }

    private struct Engine {
        var cho: [Jamo] = []
        var jung: [Jamo] = []
        var jong: [Jamo] = []
        var text = ""
        var pieces: [CompositionPiece] = []

        mutating func push(_ jamo: Jamo) {
            switch jamo.kind {
            case .choseong:
                if jung.isEmpty && jong.isEmpty {
                    if cho.isEmpty {
                        cho = [jamo]
                    } else if canAppend(cho, jamo) {
                        cho.append(jamo)
                    } else {
                        flush()
                        cho = [jamo]
                    }
                } else {
                    flush()
                    cho = [jamo]
                }
            case .jungseong:
                if !jong.isEmpty {
                    flush()
                    jung = [jamo]
                } else if jung.isEmpty {
                    jung = [jamo]
                } else if canAppend(jung, jamo) {
                    jung.append(jamo)
                } else {
                    flush()
                    jung = [jamo]
                }
            case .jongseong:
                if !jung.isEmpty {
                    if jong.isEmpty {
                        jong = [jamo]
                    } else if canAppend(jong, jamo) {
                        jong.append(jamo)
                    } else {
                        flush()
                        jong = [jamo]
                    }
                } else {
                    if !cho.isEmpty || !jong.isEmpty { flush() }
                    jong = [jamo]
                }
            }
        }

        mutating func pushCharacter(_ character: Character) {
            flush()
            text.append(character)
            if character.isNumber {
                pieces.append(.digit)
            } else if !character.isWhitespace {
                pieces.append(.symbol)
            }
        }

        mutating func flush() {
            let rendered = renderOpen()
            text += rendered.text
            pieces += rendered.pieces
            cho = []
            jung = []
            jong = []
        }

        private func canAppend(_ parts: [Jamo], _ next: Jamo) -> Bool {
            guard let current = combined(parts) else { return false }
            return Hangul.merge(current, next) != nil
        }

        private func combined(_ parts: [Jamo]) -> Jamo? {
            guard var acc = parts.first else { return nil }
            for part in parts.dropFirst() {
                guard let merged = Hangul.merge(acc, part) else { return nil }
                acc = merged
            }
            return acc
        }

        private func renderOpen() -> (text: String, pieces: [CompositionPiece]) {
            let choJ = combined(cho)
            let jungJ = combined(jung)
            let jongJ = combined(jong)
            if let choJ, let jungJ {
                let syllable = Hangul.syllable(cho: choJ.scalar, jung: jungJ.scalar, jong: jongJ?.scalar)
                return (String(syllable), [.syllable])
            }
            var text = ""
            var pieces: [CompositionPiece] = []
            if let choJ {
                text.append(choJ.compat)
                pieces.append(.bareChoseong)
            }
            if let jungJ {
                text.append(jungJ.compat)
                pieces.append(.bareJungseong)
            }
            if let jongJ {
                text.append(jongJ.compat)
                pieces.append(.bareJongseong)
            }
            return (text, pieces)
        }
    }
}
