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

    private(set) var language: Language
    private var indices: [Language: [Entry]] = [:]
    private var entries: [Entry] = []
    private var learned: [String: Int] = [:]
    private var userOnly: [UserWord] = []
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let learnedKey = "learned.v1"

    init(language: Language, bundle: Bundle, defaults: UserDefaults = UserDefaults.standard) {
        self.language = language
        self.bundle = bundle
        self.defaults = defaults
        if let data = defaults.data(forKey: learnedKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            learned = decoded
        }
        activate(language)
    }

    func setLanguage(_ newLanguage: Language) {
        language = newLanguage
        activate(newLanguage)
    }

    func resetLearned() {
        learned = [:]
        userOnly = []
        defaults.removeObject(forKey: learnedKey)
    }

    // MARK: Carga

    private func activate(_ lang: Language) {
        if indices[lang] == nil {
            indices[lang] = SureTypeEngine.load(resource: "dict_" + lang.rawValue, bundle: bundle)
        }
        entries = indices[lang] ?? []
        rebuildUserOnly()
    }

    private static func load(resource: String, bundle: Bundle) -> [Entry] {
        guard let url = bundle.url(forResource: resource, withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
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

    private func rebuildUserOnly() {
        var list: [UserWord] = []
        for (word, count) in learned {
            if existsInBase(word) { continue }
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

    private func existsInBase(_ word: String) -> Bool {
        let keys = KeyMap.keySequence(for: word)
        if keys.isEmpty { return false }
        var i = lowerBound(keys)
        while i < entries.count && entries[i].keys == keys {
            if entries[i].display == word { return true }
            i += 1
        }
        return false
    }

    private func boost(for word: String) -> Float {
        guard let count = learned[word] else { return 0 }
        return 2.0 * Float(log(Double(count) + 1.0))
    }

    /// Comprueba las letras elegidas a mano contra una palabra del diccionario.
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

    // MARK: API principal

    func suggest(_ slots: [Slot]) -> Suggestions {
        if slots.isEmpty {
            return Suggestions(words: [], isLiteral: false)
        }

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
        let seqLength = seq.utf8.count
        let limit = 10

        // 1) Palabras del diccionario: exactas (mismo largo) y completaciones (mas largas)
        var main: [Scored] = []
        var i = lowerBound(seq)
        while i < entries.count {
            let e = entries[i]
            if !e.keys.hasPrefix(seq) { break }
            i += 1
            let exact = e.keys.utf8.count == seqLength
            let score = e.base + boost(for: e.display) + (exact ? 3.0 : 0.0)
            if main.count >= limit, let last = main.last, score <= last.score { continue }
            if !matches(e.display, explicit) { continue }
            insert(Scored(text: e.display, score: score), into: &main, limit: limit)
        }

        // 2) Palabras nuevas que el usuario ha ido aprendiendo
        for u in userOnly {
            if !u.keys.hasPrefix(seq) { continue }
            if !matches(u.word, explicit) { continue }
            let exact = u.keys.utf8.count == seqLength
            let score = 1.0 + 2.0 * Float(log(Double(u.count) + 1.0)) + (exact ? 3.0 : 0.0)
            insert(Scored(text: u.word, score: score), into: &main, limit: limit)
        }

        // 3) Autocorreccion: palabras que se escriben con una tecla vecina, teclas cambiadas o una tecla de mas
        // Van siempre al final de la lista: se llega a ellas con la tecla de rotar.
        var fuzzy: [Scored] = []
        if explicit.isEmpty && seqLength >= 2 {
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
                j += 1
                if exclude.contains(e.display) { continue }
                let score = e.base + boost(for: e.display) - 5.0
                insert(Scored(text: e.display, score: score), into: &result, limit: limit)
            }
        }
        return result
    }

    // MARK: Aprendizaje

    /// Suma un uso a la palabra elegida. Las palabras que no estan en el diccionario
    /// solo se aprenden si `allowNew` es true (cuando las deletreaste letra por letra).
    func learn(_ word: String, allowNew: Bool) {
        let w = word.trimmingCharacters(in: CharacterSet.whitespaces)
        if w.count < 2 { return }

        let inBase = existsInBase(w)
        let seen = learned[w] != nil
        if !inBase && !seen && !allowNew { return }

        learned[w, default: 0] += 1

        if !inBase {
            if seen {
                if let idx = userOnly.firstIndex(where: { $0.word == w }) {
                    userOnly[idx].count += 1
                }
            } else {
                let keys = KeyMap.keySequence(for: w)
                if !keys.isEmpty {
                    userOnly.append(UserWord(word: w, keys: keys, count: 1))
                }
            }
        }

        if learned.count > 6000 {
            learned = learned.filter { $0.value > 1 }
            rebuildUserOnly()
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(learned) {
            defaults.set(data, forKey: learnedKey)
        }
    }
}
