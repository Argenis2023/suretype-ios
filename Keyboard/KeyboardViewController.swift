import UIKit

final class KeyboardViewController: UIInputViewController {

    // MARK: - Estado

    private enum Layer {
        case letters
        case numbers
        case symbols
    }

    private enum ShiftState {
        case off
        case once
        case locked
    }

    /// Lo ultimo que escribio este teclado (sin leer nada del campo, que es lento)
    private enum LastKind {
        case other
        case letter
        case spaceAfterWord
        case spaceOther
    }

    private let canvas = KeyboardCanvas()
    private var heightConstraint: NSLayoutConstraint?

    private var activeLayer: Layer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast

    private var language = "es"
    private var spellCode: String?
    private let checker = UITextChecker()
    private var learned: Set<String> = []

    private var lastKind: LastKind = .other
    private var lastSpaceTime = Date.distantPast
    private var lastProxyOp = Date.distantPast

    // Palabra marcada como mal escrita y sus correcciones
    private var flaggedWord: String?
    private var flaggedTrailing = ""
    private var flaggedSuggestions: [String] = []

    private var spellWork: DispatchWorkItem?
    private var autoShiftWork: DispatchWorkItem?

    private var letterKeys: [KeyButton] = []
    private var shiftButton: KeyButton?
    private var globeButton: KeyButton?

    private var backspaceDelayTimer: Timer?
    private var backspaceRepeatTimer: Timer?

    private var popupStartX: CGFloat = 0

    private static let accents: [Character: [String]] = [
        "a": ["a", "\u{00E1}"],
        "e": ["e", "\u{00E9}"],
        "i": ["i", "\u{00ED}"],
        "o": ["o", "\u{00F3}"],
        "u": ["u", "\u{00FA}", "\u{00FC}"],
        "n": ["n", "\u{00F1}"],
        "c": ["c", "\u{00E7}"]
    ]

    // MARK: - Ciclo de vida

    override func viewDidLoad() {
        super.viewDidLoad()

        language = UserDefaults.standard.string(forKey: "language") ?? "es"
        if language != "es" && language != "en" { language = "es" }
        if let saved = UserDefaults.standard.array(forKey: "learnedWords.v2") as? [String] {
            learned = Set(saved)
        }
        resolveSpellLanguage()

        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let h = view.heightAnchor.constraint(equalToConstant: 262)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h

        configureBar()
        rebuildKeys()

        // Calienta el corrector en segundo plano para que la primera revision no se note
        DispatchQueue.global(qos: .utility).async {
            let warm = UITextChecker()
            _ = warm.rangeOfMisspelledWord(in: "hola", range: NSRange(location: 0, length: 4), startingAt: 0, wrap: false, language: "es_ES")
            _ = warm.rangeOfMisspelledWord(in: "hello", range: NSRange(location: 0, length: 5), startingAt: 0, wrap: false, language: "en_US")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastKind = .other
        updateAutoShift()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let compact = traitCollection.verticalSizeClass == .compact
        let target: CGFloat = compact ? 200 : 262
        if let c = heightConstraint, c.constant != target {
            c.constant = target
        }
        if let globe = globeButton {
            let shouldHide = !needsInputModeSwitchKey
            if globe.isHidden != shouldHide {
                globe.isHidden = shouldHide
                canvas.setNeedsLayout()
            }
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        handleContextChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        handleContextChange()
    }

    /// Los cambios que hace este mismo teclado no se revisan (leer el campo en cada letra era lo que lo hacia lento).
    private func handleContextChange() {
        if Date().timeIntervalSince(lastProxyOp) < 0.35 { return }
        lastKind = .other
        scheduleAutoShift()
        scheduleSpellCheck(delay: 0.25)
    }

    // MARK: - Barra de correcciones

    private func configureBar() {
        canvas.bar.languageButton.setTitle(language.uppercased(), for: .normal)
        canvas.bar.languageButton.addAction(UIAction { [weak self] _ in
            self?.toggleLanguage()
        }, for: .touchUpInside)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleLanguageHold(_:)))
        hold.minimumPressDuration = 1.5
        canvas.bar.languageButton.addGestureRecognizer(hold)

        canvas.bar.onSelect = { [weak self] index in
            self?.selectBarItem(index)
        }
    }

    @objc private func handleLanguageHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            learned.removeAll()
            UserDefaults.standard.removeObject(forKey: "learnedWords.v2")
            clearFlag()
            canvas.bar.showMessage("Palabras guardadas borradas")
        }
    }

    private func toggleLanguage() {
        language = (language == "es") ? "en" : "es"
        UserDefaults.standard.set(language, forKey: "language")
        canvas.bar.languageButton.setTitle(language.uppercased(), for: .normal)
        resolveSpellLanguage()
        if spellCode == nil {
            canvas.bar.showMessage("Sin corrector para este idioma")
        } else {
            scheduleSpellCheck(delay: 0.05)
        }
    }

    private func resolveSpellLanguage() {
        let available = UITextChecker.availableLanguages
        let prefs: [String] = (language == "es")
            ? ["es_CL", "es_MX", "es_ES", "es_US", "es"]
            : ["en_US", "en_GB", "en"]
        var found: String?
        for p in prefs {
            for a in available where a.replacingOccurrences(of: "-", with: "_") == p {
                found = a
                break
            }
            if found != nil { break }
        }
        if found == nil {
            for a in available where a.lowercased().hasPrefix(language) {
                found = a
                break
            }
        }
        spellCode = found
    }

    private func scheduleSpellCheck(delay: TimeInterval) {
        spellWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runSpellCheck()
        }
        spellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearFlag() {
        if flaggedWord == nil { return }
        flaggedWord = nil
        flaggedSuggestions = []
        canvas.bar.flagFirst = false
        canvas.bar.update(candidates: [], current: -1)
    }

    /// Devuelve la ultima palabra antes del cursor (si acaba de terminar con un espacio, tambien).
    private func trailingWord(in context: String) -> (word: String, trailing: String)? {
        var chars = Array(context.suffix(60))
        var trailing = ""
        if let last = chars.last, last == " " {
            trailing = " "
            chars.removeLast()
        }
        var word: [Character] = []
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if c.isLetter || c == "'" || c == "\u{2019}" {
                word.append(c)
                i -= 1
            } else {
                break
            }
        }
        word.reverse()
        while let f = word.first, f == "'" || f == "\u{2019}" { word.removeFirst() }
        while let l = word.last, l == "'" || l == "\u{2019}" { word.removeLast() }
        if word.count < 2 { return nil }
        // Direcciones de correo, usuarios, etc.
        if i >= 0 {
            let before = chars[i]
            if before == "@" || before == "/" || before == "#" || before.isNumber { return nil }
        }
        // iPhone, NASA, etc.: se dejan en paz
        for c in word.dropFirst() where c.isUppercase { return nil }
        return (String(word), trailing)
    }

    private func matchCase(_ guess: String, like word: String) -> String {
        if word.count > 1 && word == word.uppercased() { return guess.uppercased() }
        if let f = word.first, f.isUppercase {
            return guess.prefix(1).uppercased() + String(guess.dropFirst())
        }
        return guess
    }

    private func runSpellCheck() {
        spellWork = nil
        guard activeLayer == .letters, let code = spellCode else {
            clearFlag()
            return
        }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let found = trailingWord(in: context) else {
            clearFlag()
            return
        }
        let word = found.word
        if learned.contains(word.lowercased()) {
            clearFlag()
            return
        }
        let length = (word as NSString).length
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: length), startingAt: 0, wrap: false, language: code)
        if range.location == NSNotFound {
            clearFlag()
            return
        }
        let guesses = checker.guesses(forWordRange: range, in: word, language: code) ?? []
        var list: [String] = []
        for g in guesses {
            let cased = matchCase(g, like: word)
            if cased != word && !list.contains(cased) {
                list.append(cased)
            }
            if list.count == 3 { break }
        }
        flaggedWord = word
        flaggedTrailing = found.trailing
        flaggedSuggestions = list
        canvas.bar.flagFirst = true
        canvas.bar.update(candidates: [word] + list, current: -1)
    }

    /// Posicion 0: la palabra tal cual (al tocarla se guarda como correcta). Las demas: correcciones.
    private func selectBarItem(_ index: Int) {
        guard let word = flaggedWord else { return }
        if index == 0 {
            learned.insert(word.lowercased())
            UserDefaults.standard.set(Array(learned), forKey: "learnedWords.v2")
            clearFlag()
            canvas.bar.showMessage("\"\(word)\" guardada como correcta")
            return
        }
        let i = index - 1
        if i < 0 || i >= flaggedSuggestions.count { return }
        let replacement = flaggedSuggestions[i]
        let count = word.count + flaggedTrailing.count
        for _ in 0..<count {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(replacement + " ")
        let now = Date()
        lastProxyOp = now
        lastSpaceTime = now
        lastKind = .spaceAfterWord
        clearFlag()
        scheduleAutoShift()
    }

    // MARK: - Construccion de teclas

    private func rebuildKeys() {
        letterKeys.removeAll()
        shiftButton = nil
        globeButton = nil

        let rows: [[RowItem]]
        switch activeLayer {
        case .letters:
            rows = lettersRows()
        case .numbers:
            rows = symbolRows(page: 1)
        case .symbols:
            rows = symbolRows(page: 2)
        }
        canvas.setRows(rows)
        if let globe = globeButton {
            globe.isHidden = !needsInputModeSwitchKey
        }
        refreshShiftAppearance()
        refreshLetterTitles()
    }

    private func makeKey(title: String?, symbol: String?, kind: KeyKind) -> KeyButton {
        let b = KeyButton(kind: kind)
        if let t = title {
            b.setTitle(t, for: .normal)
        }
        if let s = symbol {
            b.setImage(UIImage(systemName: s), for: .normal)
        }
        return b
    }

    private func makeLetterKey(_ letters: [Character]) -> KeyButton {
        let b = makeKey(title: nil, symbol: nil, kind: .letter)
        b.keyId = letters.first
        b.letters = letters
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self = self, let b = b else { return }
            let idx = b.letterIndex(forX: b.lastTouchX)
            self.typeLetter(String(b.letters[idx]))
        }, for: .touchUpInside)
        b.onLongPressChoice = { [weak self] choice in
            self?.typeLetter(choice.lowercased())
        }
        b.installLongPress(target: self, action: #selector(handleKeyLongPress(_:)))
        letterKeys.append(b)
        return b
    }

    private func makeBackspaceKey() -> KeyButton {
        let b = makeKey(title: nil, symbol: "delete.left", kind: .function)
        b.addAction(UIAction { [weak self] _ in
            self?.backspaceDown()
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            self?.backspaceUp()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func makeReturnKey() -> KeyButton {
        let b = makeKey(title: nil, symbol: "return", kind: .function)
        b.addAction(UIAction { [weak self] _ in
            self?.pressReturn()
        }, for: .touchUpInside)
        return b
    }

    private func makeSpaceKey() -> KeyButton {
        let b = makeKey(title: nil, symbol: nil, kind: .letter)
        b.setTitle("espacio", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        b.addAction(UIAction { [weak self] _ in
            self?.pressSpace()
        }, for: .touchDown)
        return b
    }

    private func makeGlobeKey() -> KeyButton {
        let b = makeKey(title: nil, symbol: "globe", kind: .function)
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton = b
        return b
    }

    private func makeLayerKey(title: String, target: Layer) -> KeyButton {
        let b = makeKey(title: title, symbol: nil, kind: .function)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        b.addAction(UIAction { [weak self] _ in
            self?.switchLayer(target)
        }, for: .touchUpInside)
        return b
    }

    private func makeSymbolKey(_ s: String) -> KeyButton {
        let b = makeKey(title: s, symbol: nil, kind: .letter)
        b.addAction(UIAction { [weak self] _ in
            self?.insertSymbol(s)
        }, for: .touchUpInside)
        return b
    }

    private func lettersRows() -> [[RowItem]] {
        let row1: [[Character]] = [["q", "w"], ["e", "r"], ["t", "y"], ["u", "i"], ["o", "p"]]
        let row2: [[Character]] = [["a", "s"], ["d", "f"], ["g", "h"], ["j", "k"], ["l", "\u{00F1}"]]
        let row3: [[Character]] = [["z", "x"], ["c", "v"], ["b", "n"], ["m"]]

        var r1: [RowItem] = []
        for l in row1 { r1.append(RowItem(view: makeLetterKey(l), weight: 1.0)) }

        var r2: [RowItem] = []
        for l in row2 { r2.append(RowItem(view: makeLetterKey(l), weight: 1.0)) }

        let shiftKey = makeKey(title: nil, symbol: "shift", kind: .function)
        shiftKey.addAction(UIAction { [weak self] _ in
            self?.pressShift()
        }, for: .touchUpInside)
        shiftButton = shiftKey

        var r3: [RowItem] = [RowItem(view: shiftKey, weight: 1.4)]
        for l in row3 { r3.append(RowItem(view: makeLetterKey(l), weight: 1.0)) }
        r3.append(RowItem(view: makeBackspaceKey(), weight: 1.4))

        let comma = makeKey(title: ",", symbol: nil, kind: .letter)
        comma.addAction(UIAction { [weak self] _ in
            self?.insertSymbol(",")
        }, for: .touchUpInside)

        let punct = makeKey(title: ".", symbol: nil, kind: .letter)
        punct.longPressOptions = [".", "?", "!", "\u{00BF}", "\u{00A1}", "'"]
        punct.addAction(UIAction { [weak self] _ in
            self?.insertSymbol(".")
        }, for: .touchUpInside)
        punct.onLongPressChoice = { [weak self] choice in
            self?.insertSymbol(choice)
        }
        punct.installLongPress(target: self, action: #selector(handleKeyLongPress(_:)))

        let r4: [RowItem] = [
            RowItem(view: makeLayerKey(title: "123", target: .numbers), weight: 1.3),
            RowItem(view: makeGlobeKey(), weight: 1.0),
            RowItem(view: comma, weight: 1.0),
            RowItem(view: makeSpaceKey(), weight: 4.0),
            RowItem(view: punct, weight: 1.0),
            RowItem(view: makeReturnKey(), weight: 1.5)
        ]
        return [r1, r2, r3, r4]
    }

    private func symbolRows(page: Int) -> [[RowItem]] {
        let top: [String]
        let middle: [String]
        if page == 1 {
            top = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            middle = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        } else {
            top = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            middle = ["_", "\\", "|", "~", "<", ">", "\u{20AC}", "\u{00A3}", "\u{00A5}", "\u{2022}"]
        }
        let bottom: [String] = [".", ",", "?", "!", "'", "\u{00BF}", "\u{00A1}"]

        var r1: [RowItem] = []
        for s in top { r1.append(RowItem(view: makeSymbolKey(s), weight: 1.0)) }
        var r2: [RowItem] = []
        for s in middle { r2.append(RowItem(view: makeSymbolKey(s), weight: 1.0)) }

        let toggle = makeLayerKey(title: page == 1 ? "#+=" : "123", target: page == 1 ? Layer.symbols : Layer.numbers)
        var r3: [RowItem] = [RowItem(view: toggle, weight: 1.4)]
        for s in bottom { r3.append(RowItem(view: makeSymbolKey(s), weight: 1.0)) }
        r3.append(RowItem(view: makeBackspaceKey(), weight: 1.4))

        let r4: [RowItem] = [
            RowItem(view: makeLayerKey(title: "ABC", target: .letters), weight: 1.4),
            RowItem(view: makeGlobeKey(), weight: 1.0),
            RowItem(view: makeSpaceKey(), weight: 5.0),
            RowItem(view: makeReturnKey(), weight: 1.6)
        ]
        return [r1, r2, r3, r4]
    }

    private func switchLayer(_ target: Layer) {
        activeLayer = target
        clearFlag()
        rebuildKeys()
        if target == .letters {
            updateAutoShift()
        }
    }

    // MARK: - Pulsacion larga (tildes y puntuacion)

    @objc private func handleKeyLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let key = gesture.view as? KeyButton else { return }
        let location = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            var base = key.longPressOptions
            if !key.letters.isEmpty {
                let idx = key.letterIndex(forX: gesture.location(in: key).x)
                let letter = key.letters[idx]
                base = KeyboardViewController.accents[letter] ?? []
            }
            if base.isEmpty { return }
            popupStartX = location.x
            let upper = (shift != .off) && key.keyId != nil
            let options = base.map { upper ? $0.uppercased() : $0 }
            canvas.showPopup(options: options, above: key)
        case .changed:
            canvas.popup.updateSelection(dx: location.x - popupStartX)
        case .ended:
            let choice = canvas.popup.selectedOption
            canvas.hidePopup()
            if let c = choice {
                key.onLongPressChoice?(c)
            }
        default:
            canvas.hidePopup()
        }
    }

    // MARK: - Escritura

    private func typeLetter(_ lower: String) {
        clearFlag()
        let text = (shift == .off) ? lower : lower.uppercased()
        textDocumentProxy.insertText(text)
        lastProxyOp = Date()
        lastKind = .letter
        if shift == .once {
            shift = .off
            refreshShiftAppearance()
            refreshLetterTitles()
        }
        scheduleSpellCheck(delay: 0.35)
    }

    private func pressSpace() {
        let now = Date()
        clearFlag()
        if lastKind == .spaceAfterWord && now.timeIntervalSince(lastSpaceTime) < 0.7 {
            // Doble espacio: el espacio pasa a ser punto y espacio
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastProxyOp = now
            lastSpaceTime = now
            lastKind = .spaceOther
            spellWork?.cancel()
            if activeLayer != .letters {
                activeLayer = .letters
                rebuildKeys()
            }
            if shift == .off {
                shift = .once
                refreshShiftAppearance()
                refreshLetterTitles()
            }
            return
        }
        textDocumentProxy.insertText(" ")
        lastProxyOp = now
        lastSpaceTime = now
        lastKind = (lastKind == .letter) ? .spaceAfterWord : .spaceOther
        if activeLayer != .letters {
            activeLayer = .letters
            rebuildKeys()
        }
        scheduleSpellCheck(delay: 0.08)
        scheduleAutoShift()
    }

    private func pressReturn() {
        clearFlag()
        textDocumentProxy.insertText("\n")
        lastProxyOp = Date()
        lastKind = .other
        spellWork?.cancel()
        scheduleAutoShift()
    }

    private func insertSymbol(_ s: String) {
        clearFlag()
        textDocumentProxy.insertText(s)
        lastProxyOp = Date()
        lastKind = (s.first?.isNumber ?? false) ? .letter : .other
        spellWork?.cancel()
        scheduleAutoShift()
    }

    private func pressBackspace() {
        textDocumentProxy.deleteBackward()
        lastProxyOp = Date()
        lastKind = .other
        scheduleSpellCheck(delay: 0.35)
        scheduleAutoShift()
    }

    private func backspaceDown() {
        clearFlag()
        pressBackspace()
        backspaceUp()
        let delay = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let repeater = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.pressBackspace()
            }
            RunLoop.main.add(repeater, forMode: RunLoop.Mode.common)
            self.backspaceRepeatTimer = repeater
        }
        RunLoop.main.add(delay, forMode: RunLoop.Mode.common)
        backspaceDelayTimer = delay
    }

    private func backspaceUp() {
        backspaceDelayTimer?.invalidate()
        backspaceDelayTimer = nil
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    // MARK: - Mayusculas

    private func pressShift() {
        let now = Date()
        switch shift {
        case .off:
            shift = .once
        case .once:
            shift = (now.timeIntervalSince(lastShiftTap) < 0.4) ? ShiftState.locked : ShiftState.off
        case .locked:
            shift = .off
        }
        lastShiftTap = now
        refreshShiftAppearance()
        refreshLetterTitles()
    }

    private func refreshShiftAppearance() {
        guard let b = shiftButton else { return }
        switch shift {
        case .off:
            b.setImage(UIImage(systemName: "shift"), for: .normal)
            b.isActiveKey = false
        case .once:
            b.setImage(UIImage(systemName: "shift.fill"), for: .normal)
            b.isActiveKey = true
        case .locked:
            b.setImage(UIImage(systemName: "capslock.fill"), for: .normal)
            b.isActiveKey = true
        }
    }

    private func refreshLetterTitles() {
        let upper = (shift != .off)
        for key in letterKeys {
            let parts = key.letters.map { upper ? String($0).uppercased() : String($0) }
            key.setTitle(parts.joined(separator: "  "), for: .normal)
        }
    }

    private func shouldAutoCapitalize() -> Bool {
        let type = textDocumentProxy.autocapitalizationType
        if type == UITextAutocapitalizationType.none { return false }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if context.isEmpty { return true }
        if type == UITextAutocapitalizationType.allCharacters { return true }
        if context.hasSuffix("\n") { return true }
        if type == UITextAutocapitalizationType.words { return context.hasSuffix(" ") }
        if let last = context.last, last == "\u{00BF}" || last == "\u{00A1}" { return true }
        if !context.hasSuffix(" ") { return false }
        let trimmed = context.trimmingCharacters(in: CharacterSet.whitespaces)
        guard let lastChar = trimmed.last else { return true }
        return ".!?".contains(lastChar) || lastChar == "\n"
    }

    private func scheduleAutoShift() {
        autoShiftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateAutoShift()
        }
        autoShiftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func updateAutoShift() {
        autoShiftWork = nil
        if activeLayer != .letters || shift == .locked { return }
        let want = shouldAutoCapitalize()
        if want && shift == .off {
            shift = .once
            refreshShiftAppearance()
            refreshLetterTitles()
        } else if !want && shift == .once && lastKind != .other {
            shift = .off
            refreshShiftAppearance()
            refreshLetterTitles()
        }
    }
}
