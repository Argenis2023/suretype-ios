import UIKit

// MARK: - Colores

enum Theme {
    static let letterKey = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1.0) : UIColor.white
    }
    static let functionKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.26, alpha: 1.0)
            : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1.0)
    }
    static let accent = UIColor.systemBlue
}

// MARK: - Tecla

enum KeyKind {
    case letter
    case function
}

/// Tecla pasiva: no recibe toques (los maneja el lienzo), solo se dibuja.
/// Asi no hay nada del aparataje de UIButton entre el dedo y la accion.
final class KeyView: UIView {
    var kind: KeyKind {
        didSet { updateColors() }
    }
    var isActiveKey: Bool = false {
        didSet { updateColors() }
    }
    var isPressed: Bool = false {
        didSet { updateColors() }
    }
    var keyId: Character?
    var letters: [Character] = []
    var longPressOptions: [String] = []

    /// Acciones que conecta el controlador. `up` recibe true si el dedo termino sobre la tecla.
    var downAction: (() -> Void)?
    /// Variante con el punto exacto del toque (coords del lienzo); si existe, se usa en vez de downAction.
    var downActionAt: ((CGPoint) -> Void)?
    var upAction: ((Bool) -> Void)?
    var onLongPressChoice: ((String) -> Void)?
    /// Modo deslizar (p. ej. barra espaciadora como trackpad): si estan puestos,
    /// la pulsacion larga entra en modo deslizar en vez de abrir el globo de letras.
    var onSlideBegin: (() -> Void)?
    var onSlide: ((CGFloat) -> Void)?

    let label = UILabel()
    private let imageView = UIImageView()

    init(kind: KeyKind) {
        self.kind = kind
        super.init(frame: CGRect.zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = 6
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0

        label.font = UIFont.systemFont(ofSize: 20)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.textAlignment = .center
        label.textColor = UIColor.label
        addSubview(label)

        imageView.contentMode = .center
        imageView.tintColor = UIColor.label
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        addSubview(imageView)

        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func setTitle(_ text: String?) {
        label.text = text
    }

    func setSymbol(_ name: String?) {
        imageView.image = name.flatMap { UIImage(systemName: $0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        imageView.frame = bounds
        // Sin camino de sombra, iOS recalcula la sombra de cada tecla en cada cambio (lento)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func updateColors() {
        let isLetterStyle = (kind == .letter) || isActiveKey
        let base: UIColor = isLetterStyle ? Theme.letterKey : Theme.functionKey
        let pressed: UIColor = isLetterStyle ? Theme.functionKey : Theme.letterKey
        backgroundColor = isPressed ? pressed : base
    }
}

// MARK: - Globo con opciones al mantener pulsado

final class LetterPopup: UIView {
    private var labels: [UILabel] = []
    private(set) var displayOptions: [String] = []
    private var initialIndex = 0
    private(set) var selectedIndex = 0
    private(set) var contentSize = CGSize.zero
    static let cellWidth: CGFloat = 38
    static let cellHeight: CGFloat = 46

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.letterKey
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    var selectedOption: String? {
        if selectedIndex >= 0 && selectedIndex < displayOptions.count {
            return displayOptions[selectedIndex]
        }
        return nil
    }

    /// Si `reversed` es true, la primera opcion queda en el extremo derecho
    /// (se usa para teclas cercanas al borde derecho de la pantalla).
    func configure(options: [String], reversed: Bool) {
        for l in labels { l.removeFromSuperview() }
        labels.removeAll()
        displayOptions = reversed ? Array(options.reversed()) : options
        initialIndex = reversed ? max(displayOptions.count - 1, 0) : 0
        selectedIndex = initialIndex
        for (i, text) in displayOptions.enumerated() {
            let label = UILabel()
            label.text = text
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 24)
            label.textColor = UIColor.label
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.frame = CGRect(x: 4 + CGFloat(i) * LetterPopup.cellWidth,
                                 y: 0,
                                 width: LetterPopup.cellWidth,
                                 height: LetterPopup.cellHeight)
            addSubview(label)
            labels.append(label)
        }
        contentSize = CGSize(width: CGFloat(displayOptions.count) * LetterPopup.cellWidth + 8, height: LetterPopup.cellHeight)
        refreshHighlight()
    }

    /// `dx` es lo que se ha movido el dedo en horizontal desde que empezo la pulsacion larga.
    func updateSelection(dx: CGFloat) {
        if displayOptions.isEmpty { return }
        let shift = Int((dx / LetterPopup.cellWidth).rounded())
        selectedIndex = min(max(initialIndex + shift, 0), displayOptions.count - 1)
        refreshHighlight()
    }

    private func refreshHighlight() {
        for (i, label) in labels.enumerated() {
            let on = (i == selectedIndex)
            label.backgroundColor = on ? Theme.accent : UIColor.clear
            label.textColor = on ? UIColor.white : UIColor.label
        }
    }
}

// MARK: - Barra de sugerencias

final class SuggestionBar: UIView {
    // Botones .custom: los .system animan el titulo con un fundido y las candidatas
    // se veian en blanco o tenues con cada tecla.
    let languageButton = UIButton(type: .custom)
    private var slotButtons: [UIButton] = []
    private let messageLabel = UILabel()
    private var windowStart = 0
    private let slotCount = 4
    var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        languageButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        languageButton.setTitleColor(UIColor.label, for: .normal)
        languageButton.backgroundColor = Theme.functionKey
        languageButton.layer.cornerRadius = 6
        addSubview(languageButton)

        for i in 0..<slotCount {
            let b = UIButton(type: .custom)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.6
            b.setTitleColor(UIColor.label, for: .normal)
            b.layer.cornerRadius = 6
            b.isHidden = true
            b.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.onSelect?(self.windowStart + i)
            }, for: .touchUpInside)
            addSubview(b)
            slotButtons.append(b)
        }

        messageLabel.font = UIFont.systemFont(ofSize: 14)
        messageLabel.textColor = UIColor.secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let langWidth: CGFloat = 44
        languageButton.frame = CGRect(x: 6, y: 6, width: langWidth, height: bounds.height - 12)
        let startX = langWidth + 12
        let slotWidth = (bounds.width - startX - 6) / CGFloat(slotCount)
        for (i, b) in slotButtons.enumerated() {
            b.frame = CGRect(x: startX + CGFloat(i) * slotWidth, y: 4, width: slotWidth - 4, height: bounds.height - 8)
        }
        messageLabel.frame = CGRect(x: startX, y: 0, width: bounds.width - startX - 6, height: bounds.height)
    }

    func update(candidates: [String], current: Int) {
        messageLabel.isHidden = true
        let start = max(0, current - (slotCount - 1))
        windowStart = start
        for (i, b) in slotButtons.enumerated() {
            let idx = start + i
            if idx < candidates.count {
                let isCurrent = (idx == current)
                b.setTitle(candidates[idx], for: .normal)
                b.titleLabel?.font = isCurrent ? UIFont.boldSystemFont(ofSize: 17) : UIFont.systemFont(ofSize: 17)
                b.backgroundColor = isCurrent ? Theme.letterKey : UIColor.clear
                b.isHidden = false
            } else {
                b.setTitle(nil, for: .normal)
                b.isHidden = true
            }
        }
    }

    func showMessage(_ text: String) {
        for b in slotButtons { b.isHidden = true }
        messageLabel.text = text
        messageLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.messageLabel.isHidden = true
        }
    }
}

// MARK: - Lienzo con las filas de teclas (maneja los toques directamente)

struct RowItem {
    let view: UIView
    let weight: CGFloat
}

final class KeyboardCanvas: UIView, UIInputViewAudioFeedback {
    let bar = SuggestionBar()
    let popup = LetterPopup()
    var barHeight: CGFloat = 40
    private var rows: [[RowItem]] = []

    /// Habilita el clic del sistema al tocar teclas (no necesita Acceso total).
    var enableInputClicksWhenVisible: Bool { return true }

    /// El controlador pone aqui como se muestran las opciones de pulsacion larga (mayusculas, etc.)
    var popupOptionsProvider: ((KeyView) -> [String])?

    // Toques en curso
    private final class TouchState {
        let key: KeyView
        var longPressTimer: Timer?
        var popupShown = false
        var slideActive = false
        var startX: CGFloat = 0
        init(key: KeyView) { self.key = key }
    }
    private var touches: [UITouch: TouchState] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addSubview(bar)
        popup.isHidden = true
        addSubview(popup)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func setRows(_ newRows: [[RowItem]]) {
        for row in rows {
            for item in row { item.view.removeFromSuperview() }
        }
        cancelAllTouches()
        rows = newRows
        for row in rows {
            for item in row { insertSubview(item.view, belowSubview: popup) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        bar.frame = CGRect(x: 0, y: 0, width: width, height: barHeight)
        let rowCount = rows.count
        if rowCount == 0 { return }

        let sideMargin: CGFloat = 3
        let hGap: CGFloat = 5
        let vGap: CGFloat = 6
        let top = barHeight + 2
        let bottomMargin: CGFloat = 8
        let rowHeight = (bounds.height - top - bottomMargin - vGap * CGFloat(rowCount - 1)) / CGFloat(rowCount)

        for (r, row) in rows.enumerated() {
            var visible: [RowItem] = []
            for item in row where !item.view.isHidden {
                visible.append(item)
            }
            var totalWeight: CGFloat = 0
            for item in visible { totalWeight += item.weight }
            if totalWeight <= 0 { continue }
            let gaps = hGap * CGFloat(max(visible.count - 1, 0))
            let usable = width - 2 * sideMargin - gaps
            var x = sideMargin
            let y = top + CGFloat(r) * (rowHeight + vGap)
            for item in visible {
                let w = usable * item.weight / totalWeight
                item.view.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                x += w + hGap
            }
        }
        bringSubviewToFront(popup)
    }

    // MARK: Toques

    /// La tecla bajo el punto (las teclas no reciben toques por si mismas).
    private func key(at point: CGPoint) -> KeyView? {
        for row in rows {
            for item in row {
                if let k = item.view as? KeyView, !k.isHidden, k.frame.contains(point) {
                    return k
                }
            }
        }
        return nil
    }

    override func touchesBegan(_ touchSet: Set<UITouch>, with event: UIEvent?) {
        for touch in touchSet {
            let point = touch.location(in: self)
            guard let k = key(at: point) else { continue }
            let state = TouchState(key: k)
            state.startX = point.x
            touches[touch] = state
            k.isPressed = true
            UIDevice.current.playInputClick()
            if let at = k.downActionAt {
                at(point)
            } else {
                k.downAction?()
            }
            if k.onSlideBegin != nil {
                let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self, weak touch] _ in
                    guard let self = self, let t = touch, let st = self.touches[t] else { return }
                    st.slideActive = true
                    st.startX = t.location(in: self).x
                    st.key.onSlideBegin?()
                }
                RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
                state.longPressTimer = timer
            } else if !k.longPressOptions.isEmpty {
                let timer = Timer(timeInterval: 0.30, repeats: false) { [weak self, weak touch] _ in
                    guard let self = self, let t = touch, let st = self.touches[t] else { return }
                    st.popupShown = true
                    st.startX = t.location(in: self).x
                    let options = self.popupOptionsProvider?(st.key) ?? st.key.longPressOptions
                    self.showPopup(options: options, above: st.key)
                }
                RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
                state.longPressTimer = timer
            }
        }
    }

    override func touchesMoved(_ touchSet: Set<UITouch>, with event: UIEvent?) {
        for touch in touchSet {
            guard let state = touches[touch] else { continue }
            let x = touch.location(in: self).x
            if state.popupShown {
                popup.updateSelection(dx: x - state.startX)
            } else if state.slideActive {
                state.key.onSlide?(x - state.startX)
            }
        }
    }

    override func touchesEnded(_ touchSet: Set<UITouch>, with event: UIEvent?) {
        for touch in touchSet {
            guard let state = touches.removeValue(forKey: touch) else { continue }
            state.longPressTimer?.invalidate()
            state.key.isPressed = false
            if state.popupShown {
                let choice = popup.selectedOption
                hidePopup()
                if let c = choice {
                    state.key.onLongPressChoice?(c)
                }
            } else if state.slideActive {
                // El deslizamiento ya hizo su trabajo; al soltar no pasa nada mas
            } else {
                let inside = state.key.frame.contains(touch.location(in: self))
                state.key.upAction?(inside)
            }
        }
    }

    override func touchesCancelled(_ touchSet: Set<UITouch>, with event: UIEvent?) {
        for touch in touchSet {
            guard let state = touches.removeValue(forKey: touch) else { continue }
            state.longPressTimer?.invalidate()
            state.key.isPressed = false
            if state.popupShown {
                hidePopup()
            } else if !state.slideActive {
                state.key.upAction?(false)
            }
        }
    }

    private func cancelAllTouches() {
        for (_, state) in touches {
            state.longPressTimer?.invalidate()
            state.key.isPressed = false
        }
        touches.removeAll()
        hidePopup()
    }

    // MARK: Globo de letras

    func showPopup(options: [String], above key: UIView) {
        let reversed = key.frame.midX > bounds.width / 2
        popup.configure(options: options, reversed: reversed)
        let popupWidth = popup.contentSize.width
        let popupHeight = popup.contentSize.height
        var x: CGFloat
        if reversed {
            x = key.frame.midX + LetterPopup.cellWidth / 2 + 4 - popupWidth
        } else {
            x = key.frame.midX - LetterPopup.cellWidth / 2 - 4
        }
        x = min(max(x, 2), bounds.width - popupWidth - 2)
        var y = key.frame.minY - popupHeight - 4
        if y < 0 { y = 0 }
        popup.frame = CGRect(x: x, y: y, width: popupWidth, height: popupHeight)
        popup.isHidden = false
        bringSubviewToFront(popup)
    }

    func hidePopup() {
        popup.isHidden = true
    }
}
