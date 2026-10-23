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
            guard !session.preedit.isEmpty else { return false }
            apply(session.backspace(), client: client)
            return true
        }
        if event.keyCode == Keymap.return || event.keyCode == Keymap.tab || event.keyCode == Keymap.escape || isNavigation(event.keyCode) {
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
        if let replace = update.replacePreviousUTF16, replace > 0 {
            let selection = client.selectedRange()
            let location = max(0, selection.location - replace)
            let length = min(replace, selection.location)
            let range = NSRange(location: location, length: length)
            let end = (update.preedit as NSString).length
            client.setMarkedText(
                marked(update.preedit),
                selectionRange: NSRange(location: end, length: 0),
                replacementRange: range
            )
            return
        }
        if !update.committed.isEmpty {
            client.insertText(update.committed, replacementRange: notFound)
        }
        let end = (update.preedit as NSString).length
        client.setMarkedText(
            marked(update.preedit),
            selectionRange: NSRange(location: end, length: 0),
            replacementRange: notFound
        )
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

    private func isNavigation(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x73, 0x74, 0x75, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E:
            return true
        default:
            return false
        }
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
