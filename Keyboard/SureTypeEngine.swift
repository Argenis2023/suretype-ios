import Foundation

// MARK: - Tipos basicos (sin UIKit, para poder probar el motor por separado)

/// Una pulsacion de la palabra en curso.
/// `.key` es una tecla SureType (ambigua, 2 letras). `.letter` es una letra elegida
/// a mano con pulsacion larga (por ejemplo una tilde o la n con tilde).
enum Slot: Equatable {
    case key(Character)
    case letter(Character)
}

enum Language: String {
    case es
    case en
}

struct Suggestions {
    var words: [String]
    /// true cuando no hubo ninguna palabra en el diccionario y se muestra el texto literal.
    var isLiteral: Bool
}

// MARK: - Tabla de teclas

/// Cada tecla se identifica con una letra mayuscula (la primera de su par).
/// Esta tabla debe ser identica a KEY_LETTERS en tools/build_dictionaries.py.
enum KeyMap {
    static let keyLetters: [Character: String] = [
        "Q": "qw",
        "E": "er",
        "T": "ty",
        "U": "ui",
        "O": "op",
        "A": "as",
        "D": "df",
        "G": "gh",
        "J": "jk",
        "L": "l\u{00F1}",
        "Z": "zx",
        "C": "cv",
        "B": "bn",
        "M": "m"
    ]

    /// Opciones que aparecen al mantener pulsada una tecla (letra exacta + tildes).
    static let popupOptions: [Character: [String]] = [
        "Q": ["q", "w"],
        "E": ["e", "\u{00E9}", "r"],
        "T": ["t", "y"],
        "U": ["u", "\u{00FA}", "\u{00FC}", "i", "\u{00ED}"],
        "O": ["o", "\u{00F3}", "p"],
        "A": ["a", "\u{00E1}", "s"],
        "D": ["d", "f"],
        "G": ["g", "h"],
        "J": ["j", "k"],
        "L": ["l", "\u{00F1}"],
        "Z": ["z", "x"],
        "C": ["c", "v"],
        "B": ["b", "n"],
        "M": ["m"]
    ]

    static let letterToKey: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (id, letters) in keyLetters {
            for c in letters {
                map[c] = id
            }
        }
        map["\u{00E1}"] = "A"
        map["\u{00E9}"] = "E"
        map["\u{00ED}"] = "U"
        map["\u{00F3}"] = "O"
        map["\u{00FA}"] = "U"
        map["\u{00FC}"] = "U"
        return map
    }()

    /// Posicion de cada tecla en la rejilla, para saber cuales son vecinas.
    static let positions: [Character: (x: Double, y: Double)] = [
        "Q": (x: 0.0, y: 0.0), "E": (x: 1.0, y: 0.0), "T": (x: 2.0, y: 0.0), "U": (x: 3.0, y: 0.0), "O": (x: 4.0, y: 0.0),
        "A": (x: 0.0, y: 1.0), "D": (x: 1.0, y: 1.0), "G": (x: 2.0, y: 1.0), "J": (x: 3.0, y: 1.0), "L": (x: 4.0, y: 1.0),
        "Z": (x: 0.5, y: 2.0), "C": (x: 1.5, y: 2.0), "B": (x: 2.5, y: 2.0), "M": (x: 3.5, y: 2.0)
    ]

    static let neighbors: [Character: [Character]] = {
        var result: [Character: [Character]] = [:]
        for (a, pa) in positions {
            var list: [Character] = []
            for (b, pb) in positions {
                if b == a { continue }
                let dx = pa.x - pb.x
                let dy = pa.y - pb.y
                if (dx * dx + dy * dy).squareRoot() <= 1.2 {
                    list.append(b)
                }
            }
            result[a] = list.sorted()
        }
        return result
    }()

    /// Secuencia de teclas de una palabra. Las tildes se ignoran y los apostrofes tambien.
    static func keySequence(for word: String) -> String {
        var out = ""
        for c in word.lowercased() {
            if let id = letterToKey[c] {
                out.append(id)
            }
        }
        return out
    }
}

// MARK: - Motor de prediccion

final class SureTypeEngine {

    private struct Entry {
        let keys: String
        let display: String
        let base: Float
    }

    private struct Scored {
        let text: String
        let score: Float
    }

    private struct UserWord {
        let word: String
        let keys: String
        var count: Int
    }

    /// Datos de un idioma: diccionario ordenado por teclas, pares de palabras y palabras mas comunes.
    private final class LanguageData {
        let entries: [Entry]
        let bigrams: [String: [String]]
        let topWords: [String]

        init(entries: [Entry], bigrams: [String: [String]], topWords: [String]) {
            self.entries = entries
            self.bigrams = bigrams
            self.topWords = topWords
        }
    }

    private(set) var language: Language
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let learnedKey = "learned.v1"
    private let pairsKey = "learnedPairs.v1"

    // La carga se hace en segundo plano; `cache` se protege con `lock`.
    private let lock = NSLock()
    private var cache: [Language: LanguageData] = [:]
    private var pendingGroup: DispatchGroup?

    private var data: LanguageData?
    private var entries: [Entry] = []
    private var boosts: [Float] = []

    private var learned: [String: Int] = [:]
    private var learnedPairs: [String: [String: Int]] = [:]
    private var userOnly: [UserWord] = []
    private var persistWork: DispatchWorkItem?

    init(language: Language, bundle: Bundle, defaults: UserDefaults = UserDefaults.standard) {
        self.language = language
        self.bundle = bundle
        self.defaults = defaults
        if let raw = defaults.data(forKey: learnedKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: raw) {
            learned = decoded
        }
        if let raw = defaults.data(forKey: pairsKey),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: raw) {
            learnedPairs = decoded
        }
        startLoad(language)
    }

    /// Ejecuta `block` en el hilo principal cuando el diccionario ya esta cargado.
    func whenReady(_ block: @escaping () -> Void) {
        if let group = pendingGroup {
            group.notify(queue: DispatchQueue.main) { [weak self] in
                self?.finishLoadIfNeeded()
                block()
            }
        } else {
            block()
        }
    }

    func setLanguage(_ newLanguage: Language) {
        language = newLanguage
        startLoad(newLanguage)
    }

    func resetLearned() {
        learned = [:]
        learnedPairs = [:]
        userOnly = []
        for i in boosts.indices { boosts[i] = 0 }
        persistWork?.cancel()
        defaults.removeObject(forKey: learnedKey)
        defaults.removeObject(forKey: pairsKey)
    }

    // MARK: Carga

    private func startLoad(_ lang: Language) {
        lock.lock()
        let cached = cache[lang]
        lock.unlock()
        if let c = cached {
            install(c)
            pendingGroup = nil
            return
        }
        data = nil
        entries = []
        boosts = []
        let group = DispatchGroup()
        group.enter()
        pendingGroup = group
        let bundle = self.bundle
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = SureTypeEngine.loadData(language: lang, bundle: bundle)
            self.lock.lock()
            self.cache[lang] = loaded
            self.lock.unlock()
            group.leave()
        }
    }

    /// Si el diccionario aun se esta cargando, espera a que termine (solo ocurre si se teclea muy pronto).
    private func finishLoadIfNeeded() {
        guard let group = pendingGroup else { return }
        group.wait()
        pendingGroup = nil
        lock.lock()
        let loaded = cache[language]
        lock.unlock()
        if let l = loaded {
            install(l)
        }
    }

    private func install(_ d: LanguageData) {
        data = d
        entries = d.entries
        boosts = [Float](repeating: 0, count: d.entries.count)
        for (word, count) in learned {
            if let idx = indexOf(word) {
                boosts[idx] = SureTypeEngine.boostValue(count)
            }
        }
        rebuildUserOnly()
    }

    private static func boostValue(_ count: Int) -> Float {
        return 3.0 * Float(log(Double(count) + 1.0))
    }

    private static func loadData(language: Language, bundle: Bundle) -> LanguageData {
        let entries = loadEntries(resource: "dict_" + language.rawValue, bundle: bundle)
        let bigrams = loadBigrams(resource: "bigram_" + language.rawValue, bundle: bundle)

        var top: [(word: String, score: Float)] = []
        for e in entries {
            if e.display.count < 2 { continue }
            if top.count >= 12, let last = top.last, e.base <= last.score { continue }
            var idx = top.count
            while idx > 0 && top[idx - 1].score < e.base {
                idx -= 1
            }
            top.insert((word: e.display, score: e.base), at: idx)
            if top.count > 12 {
                top.removeLast()
            }
        }
        return LanguageData(entries: entries, bigrams: bigrams, topWords: top.map { $0.word })
    }

    private static func readText(resource: String, bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: "txt"),
              let raw = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: raw, encoding: .utf8)
    }

    private static func loadEntries(resource: String, bundle: Bundle) -> [Entry] {
        guard let text = readText(resource: resource, bundle: bundle) else { return [] }
        var list: [Entry] = []
        list.reserveCapacity(50_000)
        text.enumerateLines { line, _ in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count == 3, let count = Double(String(parts[2])) {
                list.append(Entry(keys: String(parts[0]),
                                  display: String(parts[1]),
                                  base: Float(log(count + 1.0))))
            }
        }
        return list
    }

    private static func loadBigrams(resource: String, bundle: Bundle) -> [String: [String]] {
        guard let text = readText(resource: resource, bundle: bundle) else { return [:] }
        var table: [String: [String]] = [:]
        text.enumerateLines { line, _ in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count == 2 {
                var words: [String] = []
                for w in parts[1].split(separator: " ") {
                    words.append(String(w))
                }
                table[String(parts[0])] = words
            }
        }
        return table
    }

    private func rebuildUserOnly() {
        var list: [UserWord] = []
        for (word, count) in learned {
            if indexOf(word) != nil { continue }
            let keys = KeyMap.keySequence(for: word)
            if !keys.isEmpty {
                list.append(UserWord(word: word, keys: keys, count: count))
            }
        }
        userOnly = list
    }

    // MARK: Busqueda

    /// Primer indice cuya secuencia de teclas es >= key.
    private func lowerBound(_ key: String) -> Int {
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].keys < key {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func indexOf(_ word: String) -> Int? {
        let keys = KeyMap.keySequence(for: word)
        if keys.isEmpty { return nil }
        var i = lowerBound(keys)
        while i < entries.count && entries[i].keys == keys {
            if entries[i].display == word { return i }
            i += 1
        }
        return nil
    }

    /// Comprueba las letras elegidas a mano contra una palabra.
    private func matches(_ display: String, _ explicit: [Int: Character]) -> Bool {
        if explicit.isEmpty { return true }
        var i = 0
        for ch in display.lowercased() {
            if ch == "'" { continue }
            if let wanted = explicit[i], wanted != ch { return false }
            i += 1
        }
        return true
    }

    private func insert(_ item: Scored, into list: inout [Scored], limit: Int) {
        var idx = list.count
        while idx > 0 && list[idx - 1].score < item.score {
            idx -= 1
        }
        if idx >= limit { return }
        list.insert(item, at: idx)
        if list.count > limit {
            list.removeLast()
        }
    }

    // MARK: Contexto (palabra anterior)

    /// Palabras que suelen seguir a `previous`, mezclando el corpus y lo que el usuario ha escrito.
    private func contextWords(after previous: String?, limit: Int) -> [String] {
        guard let prev = previous, let d = data else { return [] }
        var scores: [String: Float] = [:]
        if let list = d.bigrams[prev] {
            for (rank, w) in list.enumerated() {
                scores[w] = 10.0 - Float(rank)
            }
        }
        if let pairs = learnedPairs[prev] {
            for (w, c) in pairs {
                scores[w, default: 0] += 6.0 + 2.0 * Float(log(Double(c) + 1.0))
            }
        }
        let ordered = scores.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }
        var result: [String] = []
        for item in ordered.prefix(limit) {
            result.append(item.key)
        }
        return result
    }

    /// Sugerencias para cuando no hay palabra en curso (barra entre palabras).
    func nextWords(after previous: String?, limit: Int = 4) -> [String] {
        finishLoadIfNeeded()
        var words = contextWords(after: previous, limit: limit)
        if words.count < limit, let d = data {
            for w in d.topWords {
                if words.count >= limit { break }
                if !words.contains(w) {
                    words.append(w)
                }
            }
        }
        return words
    }

    // MARK: Prediccion de la palabra en curso

    func suggest(_ slots: [Slot], previous: String?, includeFuzzy: Bool) -> Suggestions {
        if slots.isEmpty {
            return Suggestions(words: [], isLiteral: false)
        }
        finishLoadIfNeeded()

        var seq = ""
        var explicit: [Int: Character] = [:]
        for (i, slot) in slots.enumerated() {
            switch slot {
            case .key(let id):
                seq.append(id)
            case .letter(let c):
                seq.append(KeyMap.letterToKey[c] ?? "M")
                explicit[i] = c
            }
        }
        let seqBytes = Array(seq.utf8)
        let seqLength = seqBytes.count
        let limit = 10

        // 1) Diccionario: exactas (mismo largo) y completaciones (mas largas)
        var main: [Scored] = []
        var i = lowerBound(seq)
        while i < entries.count {
            let e = entries[i]
            if !e.keys.utf8.starts(with: seqBytes) { break }
            let idx = i
            i += 1
            let exact = e.keys.utf8.count == seqLength
            let score = e.base + boosts[idx] + (exact ? 3.0 : 0.0)
            if main.count >= limit, let last = main.last, score <= last.score { continue }
            if !matches(e.display, explicit) { continue }
            insert(Scored(text: e.display, score: score), into: &main, limit: limit)
        }

        // 2) Palabras que encajan con la palabra anterior reciben un empujon
        let context = contextWords(after: previous, limit: 8)
        for (rank, w) in context.enumerated() {
            let keys = KeyMap.keySequence(for: w)
            if !keys.utf8.starts(with: seqBytes) { continue }
            if !matches(w, explicit) { continue }
            var base: Float = 6.0
            if let idx = indexOf(w) {
                base = entries[idx].base + boosts[idx]
            }
            let exact = keys.utf8.count == seqLength
            let score = base + (exact ? 3.0 : 0.0) + 3.0 - 0.25 * Float(rank)
            insert(Scored(text: w, score: score), into: &main, limit: limit)
        }

        // 3) Palabras nuevas que el usuario ha ido aprendiendo
        for u in userOnly {
            if !u.keys.utf8.starts(with: seqBytes) { continue }
            if !matches(u.word, explicit) { continue }
            let exact = u.keys.utf8.count == seqLength
            let score = 1.0 + SureTypeEngine.boostValue(u.count) + (exact ? 3.0 : 0.0)
            insert(Scored(text: u.word, score: score), into: &main, limit: limit)
        }

        // 4) Autocorreccion (teclas vecinas, intercambiadas o de mas). Va siempre al final de la lista.
        var fuzzy: [Scored] = []
        if includeFuzzy && explicit.isEmpty && seqLength >= 2 {
            var known = Set<String>()
            for item in main { known.insert(item.text) }
            fuzzy = fuzzyCandidates(seq, limit: main.count < 6 ? 5 : 3, exclude: known)
        }

        var words: [String] = []
        var seen = Set<String>()
        for item in main + fuzzy {
            if seen.insert(item.text).inserted {
                words.append(item.text)
            }
        }

        if words.isEmpty {
            var literal = ""
            for slot in slots {
                switch slot {
                case .key(let id):
                    literal.append(KeyMap.keyLetters[id]?.first ?? "?")
                case .letter(let c):
                    literal.append(c)
                }
            }
            return Suggestions(words: [literal], isLiteral: true)
        }
        return Suggestions(words: words, isLiteral: false)
    }

    private func fuzzyCandidates(_ seq: String, limit: Int, exclude: Set<String>) -> [Scored] {
        let chars = Array(seq)
        var variants = Set<String>()

        // Tecla vecina por error
        for i in 0..<chars.count {
            for n in KeyMap.neighbors[chars[i]] ?? [] {
                var v = chars
                v[i] = n
                variants.insert(String(v))
            }
        }
        // Dos teclas intercambiadas
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                if chars[i] == chars[i + 1] { continue }
                var v = chars
                v.swapAt(i, i + 1)
                variants.insert(String(v))
            }
        }
        // Una tecla de mas
        if chars.count >= 3 {
            for i in 0..<chars.count {
                var v = chars
                v.remove(at: i)
                variants.insert(String(v))
            }
        }
        variants.remove(seq)

        var result: [Scored] = []
        for v in variants {
            var j = lowerBound(v)
            while j < entries.count && entries[j].keys == v {
                let e = entries[j]
                let idx = j
                j += 1
                if exclude.contains(e.display) { continue }
                let score = e.base + boosts[idx] - 5.0
                insert(Scored(text: e.display, score: score), into: &result, limit: limit)
            }
        }
        return result
    }

    // MARK: Aprendizaje

    /// Suma un uso a la palabra elegida y al par (palabra anterior, palabra).
    /// Las palabras que no estan en el diccionario solo se aprenden si `allowNew` es true
    /// (cuando las deletreaste letra por letra).
    func learn(_ word: String, previous: String?, allowNew: Bool) {
        finishLoadIfNeeded()
        let w = word.trimmingCharacters(in: CharacterSet.whitespaces)
        if w.isEmpty { return }

        let idx = indexOf(w)
        let seen = learned[w] != nil
        if idx == nil && !seen && !allowNew { return }

        let newCount = (learned[w] ?? 0) + 1
        learned[w] = newCount

        if let i = idx {
            boosts[i] = SureTypeEngine.boostValue(newCount)
        } else if seen {
            if let k = userOnly.firstIndex(where: { $0.word == w }) {
                userOnly[k].count = newCount
            }
        } else {
            let keys = KeyMap.keySequence(for: w)
            if !keys.isEmpty {
                userOnly.append(UserWord(word: w, keys: keys, count: 1))
            }
        }

        if let p = previous {
            learnedPairs[p, default: [:]][w, default: 0] += 1
        }

        if learned.count > 6000 {
            learned = learned.filter { $0.value > 1 }
            rebuildUserOnly()
        }
        if learnedPairs.count > 3000 {
            learnedPairs = learnedPairs.filter { $0.value.values.reduce(0, +) > 1 }
        }
        schedulePersist()
    }

    // MARK: Guardado

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistNow()
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Guarda ya lo aprendido (se llama tambien cuando el teclado se oculta).
    func persistNow() {
        persistWork?.cancel()
        persistWork = nil
        if let raw = try? JSONEncoder().encode(learned) {
            defaults.set(raw, forKey: learnedKey)
        }
        if let raw = try? JSONEncoder().encode(learnedPairs) {
            defaults.set(raw, forKey: pairsKey)
        }
    }
}
