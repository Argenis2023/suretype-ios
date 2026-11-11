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

    private var engine: SureTypeEngine!
    private let canvas = KeyboardCanvas()
    private var heightConstraint: NSLayoutConstraint?

    private var activeLayer: Layer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast

    // Palabra en curso
    private var slots: [Slot] = []
    private var suggestions = Suggestions(words: [], isLiteral: false)
    private var candidateIndex = 0
    private var insertedText = ""
    private var wordCase: ShiftState = .off
    private var lastProxyOp = Date.distantPast

    // Referencias a teclas que cambian de aspecto
    private var letterKeys: [KeyButton] = []
    private var shiftButton: KeyButton?
    private var globeButton: KeyButton?

    // Repeticion de la tecla borrar
    private var backspaceDelayTimer: Timer?
    private var backspaceRepeatTimer: Timer?

    private var popupStartX: CGFloat = 0

    // MARK: - Ciclo de vida

    override func viewDidLoad() {
        super.viewDidLoad()

        let saved = UserDefaults.standard.string(forKey: "language") ?? "es"
        let lang = Language(rawValue: saved) ?? Language.es
        engine = SureTypeEngine(language: lang, bundle: Bundle(for: SureTypeEngine.self))

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

        configureBar(language: lang)
        rebuildKeys()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

    private func handleContextChange() {
        if !slots.isEmpty {
            // Si el cursor se movio por fuera de nuestras ediciones, se abandona la palabra en curso
            if Date().timeIntervalSince(lastProxyOp) > 0.4 {
                let context = textDocumentProxy.documentContextBeforeInput ?? ""
                if !context.hasSuffix(insertedText) {
                    cancelComposition()
                }
            }
        } else {
            updateAutoShift()
        }
    }

    // MARK: - Barra de sugerencias

    private func configureBar(language: Language) {
        canvas.bar.languageButton.setTitle(language == Language.es ? "ES" : "EN", for: .normal)
        canvas.bar.languageButton.addAction(UIAction { [weak self] _ in
            self?.toggleLanguage()
        }, for: .touchUpInside)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleLanguageHold(_:)))
        hold.minimumPressDuration = 1.5
        canvas.bar.languageButton.addGestureRecognizer(hold)

        canvas.bar.onSelect = { [weak self] index in
            self?.selectCandidate(index)
        }
    }

    @objc private func handleLanguageHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            engine.resetLearned()
            canvas.bar.showMessage("Palabras aprendidas borradas")
        }
    }

    private func toggleLanguage() {
        commitComposition()
        let next: Language = (engine.language == Language.es) ? Language.en : Language.es
        engine.setLanguage(next)
        UserDefaults.standard.set(next.rawValue, forKey: "language")
        canvas.bar.languageButton.setTitle(next == Language.es ? "ES" : "EN", for: .normal)
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

    private func makeLetterKey(_ id: Character) -> KeyButton {
        let b = makeKey(title: nil, symbol: nil, kind: .letter)
        b.keyId = id
        b.longPressOptions = KeyMap.popupOptions[id] ?? []
        b.addAction(UIAction { [weak self] _ in
            self?.pressKey(id)
        }, for: .touchUpInside)
        b.onLongPressChoice = { [weak self] choice in
            self?.pressExplicit(choice)
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
        }, for: .touchUpInside)
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
        let row1: [Character] = ["Q", "E", "T", "U", "O"]
        let row2: [Character] = ["A", "D", "G", "J", "L"]
        let row3: [Character] = ["Z", "C", "B", "M"]

        var r1: [RowItem] = []
        for id in row1 { r1.append(RowItem(view: makeLetterKey(id), weight: 1.0)) }

        var r2: [RowItem] = []
        for id in row2 { r2.append(RowItem(view: makeLetterKey(id), weight: 1.0)) }

        let shiftKey = makeKey(title: nil, symbol: "shift", kind: .function)
        shiftKey.addAction(UIAction { [weak self] _ in
            self?.pressShift()
        }, for: .touchUpInside)
        shiftButton = shiftKey

        var r3: [RowItem] = [RowItem(view: shiftKey, weight: 1.3)]
        for id in row3 { r3.append(RowItem(view: makeLetterKey(id), weight: 1.0)) }
        r3.append(RowItem(view: makeBackspaceKey(), weight: 1.3))

        let rotate = makeKey(title: nil, symbol: "arrow.triangle.2.circlepath", kind: .function)
        rotate.addAction(UIAction { [weak self] _ in
            self?.rotate()
        }, for: .touchUpInside)

        let punct = makeKey(title: ".", symbol: nil, kind: .letter)
        punct.longPressOptions = [".", ",", "?", "!", "\u{00BF}", "\u{00A1}", "'"]
        punct.addAction(UIAction { [weak self] _ in
            self?.insertSymbol(".")
        }, for: .touchUpInside)
        punct.onLongPressChoice = { [weak self] choice in
            self?.insertSymbol(choice)
        }
        punct.installLongPress(target: self, action: #selector(handleKeyLongPress(_:)))

        let r4: [RowItem] = [
            RowItem(view: makeLayerKey(title: "123", target: .numbers), weight: 1.2),
            RowItem(view: makeGlobeKey(), weight: 1.0),
            RowItem(view: rotate, weight: 1.2),
            RowItem(view: makeSpaceKey(), weight: 2.8),
            RowItem(view: punct, weight: 1.0),
            RowItem(view: makeReturnKey(), weight: 1.4)
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
        commitComposition()
        activeLayer = target
        rebuildKeys()
        if target == .letters {
            updateAutoShift()
        }
    }

    // MARK: - Pulsacion larga (letra exacta, tildes, puntuacion)

    @objc private func handleKeyLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let key = gesture.view as? KeyButton else { return }
        let location = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            if key.longPressOptions.isEmpty { return }
            popupStartX = location.x
            let upper = (shift != .off) && key.keyId != nil
            let options = key.longPressOptions.map { upper ? $0.uppercased() : $0 }
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

    // MARK: - Palabra en curso

    private func pressKey(_ id: Character) {
        beginWordIfNeeded()
        slots.append(Slot.key(id))
        refreshSuggestions()
    }

    private func pressExplicit(_ text: String) {
        guard let c = text.lowercased().first else { return }
        beginWordIfNeeded()
        slots.append(Slot.letter(c))
        refreshSuggestions()
    }

    private func beginWordIfNeeded() {
        if slots.isEmpty {
            wordCase = shift
            insertedText = ""
            if shift == .once {
                shift = .off
                refreshShiftAppearance()
                refreshLetterTitles()
            }
        }
    }

    private func refreshSuggestions() {
        suggestions = engine.suggest(slots)
        candidateIndex = 0
        renderComposition()
    }

    private func currentWord() -> String {
        if candidateIndex >= 0 && candidateIndex < suggestions.words.count {
            return suggestions.words[candidateIndex]
        }
        return ""
    }

    private func applyCase(_ word: String) -> String {
        switch wordCase {
        case .off:
            return word
        case .locked:
            return word.uppercased()
        case .once:
            return word.prefix(1).uppercased() + String(word.dropFirst())
        }
    }

    private func renderComposition() {
        if slots.isEmpty {
            replaceInserted(with: "")
            canvas.bar.update(candidates: [], current: 0)
            return
        }
        replaceInserted(with: applyCase(currentWord()))
        let shown = suggestions.words.map { applyCase($0) }
        canvas.bar.update(candidates: shown, current: candidateIndex)
    }

    /// Cambia el texto de la palabra en curso tocando solo la parte que difiere.
    private func replaceInserted(with newText: String) {
        let old = Array(insertedText)
        let new = Array(newText)
        var common = 0
        while common < old.count && common < new.count && old[common] == new[common] {
            common += 1
        }
        let toDelete = old.count - common
        if toDelete > 0 {
            for _ in 0..<toDelete {
                textDocumentProxy.deleteBackward()
            }
        }
        if common < new.count {
            textDocumentProxy.insertText(String(new[common...]))
        }
        insertedText = newText
        lastProxyOp = Date()
    }

    private func rotate() {
        if slots.isEmpty || suggestions.words.count < 2 { return }
        candidateIndex = (candidateIndex + 1) % suggestions.words.count
        renderComposition()
    }

    private func selectCandidate(_ index: Int) {
        if slots.isEmpty || index < 0 || index >= suggestions.words.count { return }
        candidateIndex = index
        renderComposition()
        commitComposition()
        textDocumentProxy.insertText(" ")
        lastProxyOp = Date()
    }

    /// Da por terminada la palabra: la aprende y deja el texto como esta.
    private func commitComposition() {
        if slots.isEmpty { return }
        var word = currentWord()
        var allExplicit = true
        for slot in slots {
            if case Slot.key = slot {
                allExplicit = false
            }
        }
        let deliberate = suggestions.isLiteral && allExplicit
        if deliberate && wordCase == .once {
            word = word.prefix(1).uppercased() + String(word.dropFirst())
        }
        engine.learn(word, allowNew: deliberate)
        resetComposition()
    }

    private func resetComposition() {
        slots.removeAll()
        suggestions = Suggestions(words: [], isLiteral: false)
        candidateIndex = 0
        insertedText = ""
        wordCase = .off
        canvas.bar.update(candidates: [], current: 0)
    }

    /// Se usa cuando el cursor cambio de sitio por fuera del teclado: no se borra nada.
    private func cancelComposition() {
        resetComposition()
    }

    // MARK: - Teclas de accion

    private func pressSpace() {
        commitComposition()
        textDocumentProxy.insertText(" ")
        lastProxyOp = Date()
        if activeLayer != .letters {
            activeLayer = .letters
            rebuildKeys()
        }
        // La mayuscula automatica se calcula cuando el campo avisa del cambio de texto.
    }

    private func pressReturn() {
        commitComposition()
        textDocumentProxy.insertText("\n")
        lastProxyOp = Date()
    }

    private func insertSymbol(_ s: String) {
        commitComposition()
        textDocumentProxy.insertText(s)
        lastProxyOp = Date()
    }

    private func pressBackspace() {
        if !slots.isEmpty {
            slots.removeLast()
            if slots.isEmpty {
                replaceInserted(with: "")
                resetComposition()
            } else {
                refreshSuggestions()
            }
        } else {
            textDocumentProxy.deleteBackward()
            lastProxyOp = Date()
        }
    }

    private func backspaceDown() {
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
        if !slots.isEmpty {
            // En medio de una palabra: alterna entre Mayuscula inicial y minuscula
            wordCase = (wordCase == .off) ? ShiftState.once : ShiftState.off
            renderComposition()
            return
        }
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
            guard let id = key.keyId, let letters = KeyMap.keyLetters[id] else { continue }
            var parts: [String] = []
            for c in letters {
                let s = String(c)
                parts.append(upper ? s.uppercased() : s)
            }
            key.setTitle(parts.joined(separator: " "), for: .normal)
        }
    }

    private func shouldAutoCapitalize() -> Bool {
        let type = textDocumentProxy.autocapitalizationType
        if type == UITextAutocapitalizationType.none { return false }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if context.isEmpty { return true }
        if context.hasSuffix("\n") { return true }
        if type == UITextAutocapitalizationType.allCharacters { return true }
        if type == UITextAutocapitalizationType.words { return context.hasSuffix(" ") }
        if let last = context.last, last == "\u{00BF}" || last == "\u{00A1}" { return true }
        if !context.hasSuffix(" ") { return false }
        let trimmed = context.trimmingCharacters(in: CharacterSet.whitespaces)
        guard let lastChar = trimmed.last else { return true }
        return ".!?".contains(lastChar)
    }

    private func updateAutoShift() {
        if !slots.isEmpty || activeLayer != .letters || shift != .off { return }
        if shouldAutoCapitalize() {
            shift = .once
            refreshShiftAppearance()
            refreshLetterTitles()
        }
    }
}
