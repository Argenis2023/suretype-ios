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

    private var engine: SureTypeEngine!
    private var engineReady = false

    // Palabra en curso: solo vive en la barra hasta que das espacio o eliges una candidata
    private var slots: [Slot] = []
    private var suggestions = Suggestions(words: [], isLiteral: false)
    private var candidateIndex = 0
    private var wordCase: ShiftState = .off
    private var fuzzyComputed = false
    private var idleWork: DispatchWorkItem?

    // Contexto: palabra anterior ("<s>" = inicio de frase, nil = desconocida)
    private var previousWord: String? = "<s>"

    // Texto marcado: la palabra en curso se ve en el campo (subrayada) y se actualiza con una sola llamada
    private var markedShown = ""
    private var markedWork: DispatchWorkItem?

    // Tecla pulsada al tocar (para deshacerla si luego se elige una letra exacta con pulsacion larga)
    private var lastTouchKey: Character?

    private var lastKind: LastKind = .other
    private var lastSpaceTime = Date.distantPast
    private var lastProxyOp = Date.distantPast

    private var autoShiftWork: DispatchWorkItem?

    private var letterKeys: [KeyButton] = []
    private var shiftButton: KeyButton?
    private var globeButton: KeyButton?

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

        let h = view.heightAnchor.constraint(equalToConstant: 268)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h

        configureBar(language: lang)
        rebuildKeys()

        // El diccionario se carga en segundo plano: el teclado aparece al instante.
        engine.whenReady { [weak self] in
            self?.engineReady = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastKind = .other
        previousWord = shouldAutoCapitalize() ? "<s>" : nil
        updateAutoShift()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS retrasa los toques cerca del borde inferior (gesto del sistema): se pide que no lo haga
        if let recognizers = view.window?.gestureRecognizers {
            for r in recognizers {
                r.delaysTouchesBegan = false
                r.delaysTouchesEnded = false
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitComposition()
        engine.persistNow()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let compact = traitCollection.verticalSizeClass == .compact
        let target: CGFloat = compact ? 200 : 268
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
        if Date().timeIntervalSince(lastProxyOp) < 0.5 { return }
        lastKind = .other
        if slots.isEmpty {
            previousWord = nil
            scheduleAutoShift()
        } else {
            // Si el cursor se movio por fuera del teclado, se abandona la palabra en curso sin tocar el texto
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            if !context.hasSuffix(markedShown) {
                resetComposition(touchField: false)
                previousWord = nil
            }
        }
    }

    // MARK: - Barra de candidatas

    private func configureBar(language: Language) {
        canvas.bar.languageButton.setTitle(language.rawValue.uppercased(), for: .normal)
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
        engineReady = false
        engine.setLanguage(next)
        UserDefaults.standard.set(next.rawValue, forKey: "language")
        canvas.bar.languageButton.setTitle(next.rawValue.uppercased(), for: .normal)
        engine.whenReady { [weak self] in
            self?.engineReady = true
        }
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
        b.letters = Array(KeyMap.keyLetters[id] ?? "")
        b.longPressOptions = KeyMap.popupOptions[id] ?? []
        b.addAction(UIAction { [weak self] _ in
            self?.pressKey(id, fromTouch: true)
        }, for: .touchDown)
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

        var r3: [RowItem] = [RowItem(view: shiftKey, weight: 1.4)]
        for id in row3 { r3.append(RowItem(view: makeLetterKey(id), weight: 1.0)) }
        r3.append(RowItem(view: makeBackspaceKey(), weight: 1.4))

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
            RowItem(view: makeLayerKey(title: "123", target: .numbers), weight: 1.3),
            RowItem(view: makeGlobeKey(), weight: 1.0),
            RowItem(view: rotate, weight: 1.2),
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
        commitComposition()
        activeLayer = target
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
                if let id = key.keyId, lastTouchKey == id {
                    undoTentativeKey()
                }
                key.onLongPressChoice?(c)
            }
        default:
            canvas.hidePopup()
        }
    }

    // MARK: - Palabra en curso (solo en la barra)

    private func pressKey(_ id: Character, fromTouch: Bool = false) {
        lastKind = .other
        lastTouchKey = fromTouch ? id : nil
        beginWordIfNeeded()
        slots.append(Slot.key(id))
        refreshSuggestions()
    }

    /// La tecla ya se habia anotado al tocar; si era una pulsacion larga, se quita para poner la letra exacta.
    private func undoTentativeKey() {
        lastTouchKey = nil
        if slots.isEmpty { return }
        slots.removeLast()
        if slots.isEmpty {
            let c = wordCase
            resetComposition(touchField: true)
            if c == .once {
                shift = .once
                refreshShiftAppearance()
                refreshLetterTitles()
            }
        }
    }

    private func pressExplicit(_ text: String) {
        guard let c = text.lowercased().first else { return }
        lastKind = .other
        lastTouchKey = nil
        beginWordIfNeeded()
        slots.append(Slot.letter(c))
        refreshSuggestions()
    }

    private func beginWordIfNeeded() {
        if slots.isEmpty {
            wordCase = shift
            if shift == .once {
                shift = .off
                refreshShiftAppearance()
                refreshLetterTitles()
            }
        }
    }

    private func refreshSuggestions() {
        suggestions = engine.suggest(slots, previous: previousWord, includeFuzzy: false)
        candidateIndex = 0
        fuzzyComputed = false
        updateBar()
        scheduleMarked(delay: 0.12)
        scheduleIdleWork()
    }

    // MARK: - Texto marcado (la palabra se ve en el campo)

    private func scheduleMarked(delay: TimeInterval) {
        markedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushMarked()
        }
        markedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Deja en el campo la candidata actual, con una sola llamada.
    private func flushMarked() {
        markedWork?.cancel()
        markedWork = nil
        let target = slots.isEmpty ? "" : applyCase(currentWord())
        if target == markedShown { return }
        if target.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        } else {
            textDocumentProxy.setMarkedText(target, selectedRange: NSRange(location: (target as NSString).length, length: 0))
        }
        markedShown = target
        lastProxyOp = Date()
    }

    private func capitalizedFirst(_ word: String) -> String {
        return word.prefix(1).uppercased() + String(word.dropFirst())
    }

    private func applyCase(_ word: String) -> String {
        switch wordCase {
        case .off:
            return word
        case .locked:
            return word.uppercased()
        case .once:
            return capitalizedFirst(word)
        }
    }

    private func currentWord() -> String {
        if candidateIndex >= 0 && candidateIndex < suggestions.words.count {
            return suggestions.words[candidateIndex]
        }
        return ""
    }

    private func updateBar() {
        if slots.isEmpty {
            canvas.bar.update(candidates: [], current: -1)
            return
        }
        var shown: [String] = []
        for w in suggestions.words {
            shown.append(applyCase(w))
        }
        canvas.bar.update(candidates: shown, current: candidateIndex)
    }

    /// La autocorreccion (lo mas pesado del motor) se calcula solo cuando haces una pausa.
    private func scheduleIdleWork() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.extendWithFuzzy()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func extendWithFuzzy() {
        idleWork = nil
        if fuzzyComputed || slots.isEmpty { return }
        fuzzyComputed = true
        let full = engine.suggest(slots, previous: previousWord, includeFuzzy: true)
        let head = Array(full.words.prefix(suggestions.words.count))
        if candidateIndex == 0 || head == suggestions.words {
            suggestions = full
            if candidateIndex >= suggestions.words.count {
                candidateIndex = 0
            }
            updateBar()
            flushMarked()
        }
    }

    private func rotate() {
        if slots.isEmpty { return }
        lastKind = .other
        lastTouchKey = nil
        idleWork?.cancel()
        extendWithFuzzy()
        if suggestions.words.count >= 2 {
            candidateIndex = (candidateIndex + 1) % suggestions.words.count
            updateBar()
        }
        flushMarked()
    }

    private func selectCandidate(_ index: Int) {
        if slots.isEmpty || index < 0 || index >= suggestions.words.count { return }
        lastTouchKey = nil
        candidateIndex = index
        commitComposition()
        textDocumentProxy.insertText(" ")
        let now = Date()
        lastProxyOp = now
        lastSpaceTime = now
        lastKind = .spaceAfterWord
        scheduleAutoShift()
    }

    /// Fija la palabra en el campo, la aprende y deja la barra vacia.
    private func commitComposition() {
        if slots.isEmpty { return }
        idleWork?.cancel()
        idleWork = nil
        var word = currentWord()
        var allExplicit = true
        for slot in slots {
            if case Slot.key = slot {
                allExplicit = false
            }
        }
        let deliberate = suggestions.isLiteral && allExplicit
        if deliberate && wordCase == .once {
            word = capitalizedFirst(word)
        }
        flushMarked()
        textDocumentProxy.unmarkText()
        markedShown = ""
        lastProxyOp = Date()
        lastKind = .letter
        engine.learn(word, previous: previousWord, allowNew: deliberate)
        previousWord = word.lowercased()
        resetComposition(touchField: false)
    }

    private func resetComposition(touchField: Bool) {
        idleWork?.cancel()
        idleWork = nil
        markedWork?.cancel()
        markedWork = nil
        if touchField && !markedShown.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
            lastProxyOp = Date()
        }
        markedShown = ""
        slots.removeAll()
        suggestions = Suggestions(words: [], isLiteral: false)
        candidateIndex = 0
        wordCase = .off
        fuzzyComputed = false
        updateBar()
    }

    // MARK: - Teclas de accion

    private func pressSpace() {
        let wasComposing = !slots.isEmpty
        commitComposition()
        let now = Date()
        lastTouchKey = nil
        if !wasComposing && lastKind == .spaceAfterWord && now.timeIntervalSince(lastSpaceTime) < 0.7 {
            // Doble espacio: el espacio pasa a ser punto y espacio
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastProxyOp = now
            lastSpaceTime = now
            lastKind = .spaceOther
            previousWord = "<s>"
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
        lastKind = (wasComposing || lastKind == .letter) ? .spaceAfterWord : .spaceOther
        if activeLayer != .letters {
            activeLayer = .letters
            rebuildKeys()
        }
        scheduleAutoShift()
    }

    private func pressReturn() {
        commitComposition()
        lastTouchKey = nil
        textDocumentProxy.insertText("\n")
        lastProxyOp = Date()
        lastKind = .other
        previousWord = "<s>"
        scheduleAutoShift()
    }

    private func insertSymbol(_ s: String) {
        commitComposition()
        lastTouchKey = nil
        textDocumentProxy.insertText(s)
        lastProxyOp = Date()
        lastKind = (s.first?.isNumber ?? false) ? .letter : .other
        let endsSentence = (s == "." || s == "?" || s == "!" || s == "\u{00BF}" || s == "\u{00A1}")
        previousWord = endsSentence ? "<s>" : nil
        scheduleAutoShift()
    }

    private func pressBackspace() {
        lastKind = .other
        lastTouchKey = nil
        if !slots.isEmpty {
            slots.removeLast()
            if slots.isEmpty {
                resetComposition(touchField: true)
            } else {
                refreshSuggestions()
            }
            return
        }
        textDocumentProxy.deleteBackward()
        lastProxyOp = Date()
        previousWord = nil
        scheduleAutoShift()
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
            updateBar()
            scheduleMarked(delay: 0.05)
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
            let parts = key.letters.map { upper ? String($0).uppercased() : String($0) }
            key.setTitle(parts.joined(separator: " "), for: .normal)
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
        if activeLayer != .letters || shift == .locked || !slots.isEmpty { return }
        let want = shouldAutoCapitalize()
        if want { previousWord = "<s>" }
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
