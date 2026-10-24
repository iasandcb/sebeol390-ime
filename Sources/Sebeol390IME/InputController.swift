import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

@objc(SebeolInputController)
final class SebeolInputController: IMKInputController {
    private let session = Session(lexicon: SharedLexicon.lexicon, autoSwitch: true, mode: .korean)
    private var sawCapsLockDown = false

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask = NSEvent.EventTypeMask([.keyDown, .flagsChanged])
        return Int(mask.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        if event.type == .flagsChanged {
            return handleFlags(event, client: client)
        }
        guard event.type == .keyDown else { return false }

        let secure = IsSecureEventInputEnabled()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if secure {
            apply(session.discard(), client: client)
            return false
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            apply(session.commitDisplayed(), client: client)
            return false
        }

        if event.keyCode == Keymap.delete {
            let update = session.backspace()
            guard update.field != .none else { return false }
            apply(update, client: client)
            return true
        }
        if Keymap.isNavigation(event.keyCode) {
            apply(session.commitDisplayed(), client: client)
            return false
        }

        let shift = flags.contains(.shift)
        if event.keyCode == Keymap.space && shift {
            apply(session.toggle(), client: client)
            return true
        }
        guard let character = Keymap.qwertyCharacter(keyCode: event.keyCode, shift: shift) else {
            apply(session.commitDisplayed(), client: client)
            return false
        }
        apply(session.input(character), client: client)
        return true
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        apply(session.commitDisplayed(), client: client)
    }

    /// ESC and a client that ends composition on '.' ask for the original
    /// keystrokes. Those keys are `mr2jt` for 했어, so return the Hangul
    /// that is actually marked.
    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: session.preedit)
    }

    override func cancelComposition() {
        guard let client = client() else { return }
        apply(session.commitDisplayed(), client: client)
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "세벌식 390")
        let auto = menu.addItem(withTitle: "자동 한/영 전환", action: #selector(toggleAutoSwitch(_:)), keyEquivalent: "")
        auto.state = session.autoSwitch ? .on : .off
        auto.target = self
        menu.addItem(.separator())
        let korean = menu.addItem(withTitle: "한글 (세벌식 390)", action: #selector(selectKorean(_:)), keyEquivalent: "")
        korean.state = session.mode == .korean ? .on : .off
        korean.target = self
        let english = menu.addItem(withTitle: "영문 (QWERTY)", action: #selector(selectEnglish(_:)), keyEquivalent: "")
        english.state = session.mode == .english ? .on : .off
        english.target = self
        return menu
    }

    @objc private func toggleAutoSwitch(_ sender: Any?) {
        session.autoSwitch.toggle()
    }

    @objc private func selectKorean(_ sender: Any?) {
        if let client = client() {
            apply(session.forceMode(.korean), client: client)
        } else {
            _ = session.forceMode(.korean)
        }
    }

    @objc private func selectEnglish(_ sender: Any?) {
        if let client = client() {
            apply(session.forceMode(.english), client: client)
        } else {
            _ = session.forceMode(.english)
        }
    }

    private func handleFlags(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard event.keyCode == Keymap.capsLock else { return false }
        let down = event.modifierFlags.contains(.capsLock)
        if down && !sawCapsLockDown {
            sawCapsLockDown = true
            apply(session.toggle(), client: client)
            CapsLockReset.turnOff()
            return true
        }
        if !down {
            sawCapsLockDown = false
        }
        return true
    }

    private func apply(_ update: SessionUpdate, client: IMKTextInput) {
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)
        switch update.field {
        case .none:
            return
        case .unmark(let text):
            guard !text.isEmpty else { return }
            insertCommitting(text, client: client)
        case .insert(let text):
            guard !text.isEmpty else { return }
            insertCommitting(text, client: client)
        case .mark(let text):
            setMarked(text, replacement: notFound, client: client)
        case .replaceBeforeCaret(let utf16, let text):
            setMarked(text, replacement: rangeBeforeCaret(utf16, client: client), client: client)
        case .insertThenMark(let insert, let mark):
            if !insert.isEmpty {
                client.insertText(insert, replacementRange: notFound)
            }
            setMarked(mark, replacement: notFound, client: client)
        case .insertReplacing(let utf16, let text):
            client.insertText(text, replacementRange: rangeBeforeCaret(utf16, client: client))
        case .insertReplacingThenMark(let utf16, let insert, let mark):
            client.insertText(insert, replacementRange: rangeBeforeCaret(utf16, client: client))
            setMarked(mark, replacement: notFound, client: client)
        case .clearMarkThenInsert(let utf16, let text):
            let span = utf16 + markedLength(client)
            client.insertText(text, replacementRange: rangeBeforeCaret(span, client: client))
        case .clearMarkThenMark(let utf16, let text):
            let span = utf16 + markedLength(client)
            setMarked(text, replacement: rangeBeforeCaret(span, client: client), client: client)
        case .rewrite(let utf16, let text, let thenMark):
            let range = rangeBeforeCaret(utf16, client: client)
            if thenMark.isEmpty {
                client.insertText(text, replacementRange: range)
            } else if text.isEmpty {
                setMarked(thenMark, replacement: range, client: client)
            } else {
                client.insertText(text, replacementRange: range)
                setMarked(thenMark, replacement: notFound, client: client)
            }
        }
    }

    /// A mark is the Hangul being composed. Replacing that range commits it.
    /// `NSNotFound` inserts at the caret instead, and the client then keeps
    /// the raw keys (`mr2jt`) and puts the period after a space.
    private func insertCommitting(_ text: String, client: IMKTextInput) {
        let marked = client.markedRange()
        if marked.location != NSNotFound, marked.length > 0 {
            client.insertText(text, replacementRange: marked)
        } else {
            let notFound = NSRange(location: NSNotFound, length: NSNotFound)
            client.insertText(text, replacementRange: notFound)
        }
    }

    private func setMarked(_ text: String, replacement: NSRange, client: IMKTextInput) {
        let end = (text as NSString).length
        client.setMarkedText(
            marked(text),
            selectionRange: NSRange(location: end, length: 0),
            replacementRange: replacement
        )
    }

    private func markedLength(_ client: IMKTextInput) -> Int {
        let range = client.markedRange()
        if range.location == NSNotFound { return 0 }
        return range.length
    }

    private func rangeBeforeCaret(_ utf16: Int, client: IMKTextInput) -> NSRange {
        let selection = client.selectedRange()
        let location = max(0, selection.location - utf16)
        let length = min(utf16, selection.location)
        return NSRange(location: location, length: length)
    }

    private func marked(_ text: String) -> Any {
        guard !text.isEmpty else { return text }
        let string = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if let raw = mark(forStyle: kTSMHiliteSelectedRawText, at: range) {
            var attributes: [NSAttributedString.Key: Any] = [:]
            for (key, value) in raw {
                let name = (key.base as? String) ?? (key.base as? NSAttributedString.Key)?.rawValue
                if let name {
                    attributes[NSAttributedString.Key(name)] = value
                }
            }
            if !attributes.isEmpty {
                string.addAttributes(attributes, range: range)
            }
        }
        return string
    }
}

enum SharedLexicon {
    static let lexicon: Lexicon = {
        if let url = Bundle.main.resourceURL {
            if let loaded = try? Lexicon.load(from: url) {
                return loaded
            }
        }
        let beside = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        if let loaded = try? Lexicon.load(from: beside) {
            return loaded
        }
        return Lexicon(english: [], korean: [], abbreviations: Lexicon.defaultAbbreviations, techStems: Lexicon.defaultTechStems)
    }()
}
