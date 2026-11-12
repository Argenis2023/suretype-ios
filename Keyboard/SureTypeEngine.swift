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

// MARK: - Diccionario binario (se lee tal cual del archivo, sin parsear texto)

/// dict_XX.bin:  "STD2" | n u32 | seqOffsets u32 x(n+1) | wordOffsets u32 x(n+1)
///               | freqs f32 xn | seqBlob | wordBlob   (little-endian)
private struct BinaryDictionary {
    let count: Int
    let seqOffsets: [UInt32]
    let wordOffsets: [UInt32]
    let freqs: [Float]
    let seqBlob: [UInt8]
    let wordBlob: [UInt8]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return nil }
        guard data[0] == 0x53, data[1] == 0x54, data[2] == 0x44, data[3] == 0x32 else { return nil } // "STD2"
        let n = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        var off = 8
        func readU32(_ count: Int) -> [UInt32]? {
            let bytes = count * 4
            guard off + bytes <= data.count else { return nil }
            let out = data.withUnsafeBytes { raw -> [UInt32] in
                var arr = [UInt32](repeating: 0, count: count)
                for i in 0..<count {
                    arr[i] = raw.loadUnaligned(fromByteOffset: off + i * 4, as: UInt32.self).littleEndian
                }
                return arr
            }
            off += bytes
            return out
        }
        guard let so = readU32(n + 1), let wo = readU32(n + 1), let fbits = readU32(n) else { return nil }
        let f = fbits.map { Float(bitPattern: $0) }
        let seqLen = Int(so[n])
        let wordLen = Int(wo[n])
        guard off + seqLen + wordLen <= data.count else { return nil }
        count = n
        seqOffsets = so
        wordOffsets = wo
        freqs = f
        seqBlob = [UInt8](data[off..<(off + seqLen)])
        wordBlob = [UInt8](data[(off + seqLen)..<(off + seqLen + wordLen)])
    }

    @inline(__always) func seq(_ i: Int) -> ArraySlice<UInt8> {
        return seqBlob[Int(seqOffsets[i])..<Int(seqOffsets[i + 1])]
    }

    @inline(__always) func seqLength(_ i: Int) -> Int {
        return Int(seqOffsets[i + 1] - seqOffsets[i])
    }

    func word(_ i: Int) -> String {
        return String(decoding: wordBlob[Int(wordOffsets[i])..<Int(wordOffsets[i + 1])], as: UTF8.self)
    }

    /// Primer indice cuya secuencia es >= key.
    func lowerBound(_ key: [UInt8]) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compare(seq(mid), key) < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    @inline(__always) private func compare(_ a: ArraySlice<UInt8>, _ b: [UInt8]) -> Int {
        var i = a.startIndex
        var j = 0
        while i < a.endIndex && j < b.count {
            if a[i] != b[j] { return a[i] < b[j] ? -1 : 1 }
            i += 1
            j += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    @inline(__always) func seqHasPrefix(_ i: Int, _ prefix: [UInt8]) -> Bool {
        let s = seq(i)
        if s.count < prefix.count { return false }
        var k = s.startIndex
        for j in 0..<prefix.count {
            if s[k] != prefix[j] { return false }
            k += 1
        }
        return true
    }

    func indexOf(word w: String) -> Int? {
        let keys = Array(KeyMap.keySequence(for: w).utf8)
        if keys.isEmpty { return nil }
        var i = lowerBound(keys)
        while i < count && seqLength(i) == keys.count && seqHasPrefix(i, keys) {
            if word(i) == w { return i }
            i += 1
        }
        return nil
    }
}

/// bigram_XX.bin: "STB2" | prevCount u32 | followerTotal u32 | prevOffsets u32 x(p+1)
///                | prevWordOffsets u32 x(p+1) | (wordIdx u32, weight f32) x total | prevBlob
private struct BinaryBigrams {
    let prevCount: Int
    let prevOffsets: [UInt32]
    let prevWordOffsets: [UInt32]
    let followerIdx: [UInt32]
    let followerWeight: [Float]
    let prevBlob: [UInt8]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        guard data[0] == 0x53, data[1] == 0x54, data[2] == 0x42, data[3] == 0x32 else { return nil } // "STB2"
        let p = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        let total = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
        var off = 12
        func readU32(_ count: Int) -> [UInt32]? {
            let bytes = count * 4
            guard off + bytes <= data.count else { return nil }
            let out = data.withUnsafeBytes { raw -> [UInt32] in
                var arr = [UInt32](repeating: 0, count: count)
                for i in 0..<count {
                    arr[i] = raw.loadUnaligned(fromByteOffset: off + i * 4, as: UInt32.self).littleEndian
                }
                return arr
            }
            off += bytes
            return out
        }
        guard let po = readU32(p + 1), let pwo = readU32(p + 1) else { return nil }
        guard off + total * 8 <= data.count else { return nil }
        var fIdx = [UInt32](repeating: 0, count: total)
        var fW = [Float](repeating: 0, count: total)
        data.withUnsafeBytes { raw in
            for i in 0..<total {
                fIdx[i] = raw.loadUnaligned(fromByteOffset: off + i * 8, as: UInt32.self).littleEndian
                fW[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off + i * 8 + 4, as: UInt32.self).littleEndian)
            }
        }
        off += total * 8
        let blobLen = Int(pwo[p])
        guard off + blobLen <= data.count else { return nil }
        prevCount = p
        prevOffsets = po
        prevWordOffsets = pwo
        followerIdx = fIdx
        followerWeight = fW
        prevBlob = [UInt8](data[off..<(off + blobLen)])
    }

    /// Devuelve (indiceEnDiccionario, peso) de las palabras que suelen seguir a `prev`.
    func followers(of prev: String) -> [(idx: Int, weight: Float)] {
        let key = Array(prev.utf8)
        var lo = 0
        var hi = prevCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let s = prevBlob[Int(prevWordOffsets[mid])..<Int(prevWordOffsets[mid + 1])]
            var cmp = 0
            var i = s.startIndex
            var j = 0
            while i < s.endIndex && j < key.count {
                if s[i] != key[j] { cmp = s[i] < key[j] ? -1 : 1; break }
                i += 1
                j += 1
            }
            if cmp == 0 && s.count != key.count { cmp = s.count < key.count ? -1 : 1 }
            if cmp < 0 { lo = mid + 1 } else { hi = mid }
        }
        guard lo < prevCount else { return [] }
        let s = prevBlob[Int(prevWordOffsets[lo])..<Int(prevWordOffsets[lo + 1])]
        guard s.elementsEqual(key) else { return [] }
        var out: [(idx: Int, weight: Float)] = []
        for k in Int(prevOffsets[lo])..<Int(prevOffsets[lo + 1]) {
            out.append((idx: Int(followerIdx[k]), weight: followerWeight[k]))
        }
        return out
    }
}

// MARK: - Motor de prediccion

final class SureTypeEngine {

    private struct Scored {
        let text: String
        let score: Float
    }

    private struct UserWord {
        let word: String
        let keys: [UInt8]
        var count: Int
    }

    private final class LanguageData {
        let dict: BinaryDictionary
        let bigrams: BinaryBigrams?
        init(dict: BinaryDictionary, bigrams: BinaryBigrams?) {
            self.dict = dict
            self.bigrams = bigrams
        }
    }

    private(set) var language: Language
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let learnedKey = "learned.v2"
    private let pairsKey = "learnedPairs.v2"
    private let bySeqKey = "learnedBySeq.v2"

    // La carga se hace en segundo plano; `cache` se protege con `lock`.
    private let lock = NSLock()
    private var cache: [Language: LanguageData] = [:]
    private var loading: Set<Language> = []
    private var readyBlocks: [() -> Void] = []

    private var data: LanguageData?
    private var boosts: [Int: Float] = [:]

    /// Se llama en el hilo principal cada vez que un diccionario queda instalado
    /// (al abrir el teclado o al cambiar de idioma).
    var onInstall: (() -> Void)?

    private var learned: [String: Int] = [:]
    private var learnedPairs: [String: [String: Int]] = [:]
    /// Lo clave del SureType real: para cada secuencia exacta, la ultima palabra que elegiste gana.
    private var learnedBySeq: [String: String] = [:]
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
        if let raw = defaults.data(forKey: bySeqKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: raw) {
            learnedBySeq = decoded
        }
        startLoad(language)
    }

    var isReady: Bool {
        return data != nil
    }

    /// Ejecuta `block` en el hilo principal cuando el diccionario ya esta cargado.
    func whenReady(_ block: @escaping () -> Void) {
        if data != nil {
            block()
            return
        }
        lock.lock()
        let cached = cache[language]
        if cached == nil {
            readyBlocks.append(block)
        }
        lock.unlock()
        if let c = cached {
            install(c)
            block()
        }
    }

    func setLanguage(_ newLanguage: Language) {
        language = newLanguage
        data = nil
        boosts = [:]
        startLoad(newLanguage)
    }

    func resetLearned() {
        learned = [:]
        learnedPairs = [:]
        learnedBySeq = [:]
        userOnly = []
        boosts = [:]
        persistWork?.cancel()
        defaults.removeObject(forKey: learnedKey)
        defaults.removeObject(forKey: pairsKey)
        defaults.removeObject(forKey: bySeqKey)
    }

    // MARK: Carga (nunca bloquea el hilo principal)

    private func startLoad(_ lang: Language) {
        lock.lock()
        if let cached = cache[lang] {
            lock.unlock()
            install(cached)
            flushReadyBlocks()
            return
        }
        if loading.contains(lang) {
            lock.unlock()
            return
        }
        loading.insert(lang)
        lock.unlock()

        let bundle = self.bundle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dictURL = bundle.url(forResource: "dict_" + lang.rawValue, withExtension: "bin")
            let biURL = bundle.url(forResource: "bigram_" + lang.rawValue, withExtension: "bin")
            let dict = dictURL.flatMap { BinaryDictionary(url: $0) }
            let bigrams = biURL.flatMap { BinaryBigrams(url: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lock.lock()
                if let d = dict {
                    self.cache[lang] = LanguageData(dict: d, bigrams: bigrams)
                }
                self.loading.remove(lang)
                let ready = self.cache[lang]
                self.lock.unlock()
                if self.language == lang, let r = ready {
                    self.install(r)
                    self.flushReadyBlocks()
                    self.onInstall?()
                }
            }
        }
    }

    private func flushReadyBlocks() {
        lock.lock()
        let blocks = readyBlocks
        readyBlocks = []
        lock.unlock()
        for b in blocks { b() }
    }

    private func install(_ d: LanguageData) {
        data = d
        boosts = [:]
        for (word, count) in learned {
            if let idx = d.dict.indexOf(word: word) {
                boosts[idx] = SureTypeEngine.boostValue(count)
            }
        }
        rebuildUserOnly()
    }

    private static func boostValue(_ count: Int) -> Float {
        return min(2.2 * Float(log(Double(count) + 1.0)), 9.0)
    }

    private func rebuildUserOnly() {
        guard let d = data else { return }
        var list: [UserWord] = []
        for (word, count) in learned {
            if d.dict.indexOf(word: word) != nil { continue }
            let keys = Array(KeyMap.keySequence(for: word).utf8)
            if !keys.isEmpty {
                list.append(UserWord(word: word, keys: keys, count: count))
            }
        }
        userOnly = list
    }

    // MARK: Utiles

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

    // MARK: Prediccion de la palabra en curso

    func suggest(_ slots: [Slot], previous: String?, includeFuzzy: Bool) -> Suggestions {
        if slots.isEmpty {
            return Suggestions(words: [], isLiteral: false)
        }
        var literal = ""
        for slot in slots {
            switch slot {
            case .key(let id):
                literal.append(KeyMap.keyLetters[id]?.first ?? "?")
            case .letter(let c):
                literal.append(c)
            }
        }
        guard let d = data else {
            // El diccionario aun no termina de cargar (primeras decimas de segundo):
            // se muestran las letras literales sin congelar el teclado.
            return Suggestions(words: [literal], isLiteral: true)
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
        let seqBytes = Array(seq.utf8)
        let seqLength = seqBytes.count
        let limit = 10
        let mruWord = learnedBySeq[seq]

        // 1) Diccionario: exactas (mismo largo) y completaciones (mas largas, con castigo por letra extra)
        var main: [Scored] = []
        var i = d.dict.lowerBound(seqBytes)
        while i < d.dict.count {
            if !d.dict.seqHasPrefix(i, seqBytes) { break }
            let idx = i
            i += 1
            let entryLen = d.dict.seqLength(idx)
            let exact = entryLen == seqLength
            var score = d.dict.freqs[idx] + (boosts[idx] ?? 0)
            score += exact ? 4.0 : -0.7 * Float(entryLen - seqLength)
            if main.count >= limit, let last = main.last, score + 8.0 <= last.score { continue }
            let w = d.dict.word(idx)
            if exact && w == mruWord { score += 8.0 }
            if main.count >= limit, let last = main.last, score <= last.score { continue }
            if !matches(w, explicit) { continue }
            insert(Scored(text: w, score: score), into: &main, limit: limit)
        }

        // 2) Palabras que encajan con la palabra anterior reciben un empujon
        if let prev = previous {
            if let bi = d.bigrams {
                for f in bi.followers(of: prev) {
                    let idx = f.idx
                    if !d.dict.seqHasPrefix(idx, seqBytes) { continue }
                    let w = d.dict.word(idx)
                    if !matches(w, explicit) { continue }
                    let entryLen = d.dict.seqLength(idx)
                    let exact = entryLen == seqLength
                    var score = d.dict.freqs[idx] + (boosts[idx] ?? 0) + f.weight
                    score += exact ? 4.0 : -0.7 * Float(entryLen - seqLength)
                    if exact && w == mruWord { score += 8.0 }
                    insert(Scored(text: w, score: score), into: &main, limit: limit)
                }
            }
            if let pairs = learnedPairs[prev] {
                for (w, c) in pairs {
                    let keys = Array(KeyMap.keySequence(for: w).utf8)
                    if keys.count < seqLength || !keys.starts(with: seqBytes) { continue }
                    if !matches(w, explicit) { continue }
                    let exact = keys.count == seqLength
                    var base: Float = 4.0
                    if let idx = d.dict.indexOf(word: w) {
                        base = d.dict.freqs[idx] + (boosts[idx] ?? 0)
                    }
                    var score = base + 6.0 + 1.5 * Float(log(Double(c) + 1.0))
                    score += exact ? 4.0 : -0.7 * Float(keys.count - seqLength)
                    insert(Scored(text: w, score: score), into: &main, limit: limit)
                }
            }
        }

        // 3) Palabras nuevas que el usuario ha ido aprendiendo
        for u in userOnly {
            if u.keys.count < seqLength || !u.keys.starts(with: seqBytes) { continue }
            if !matches(u.word, explicit) { continue }
            let exact = u.keys.count == seqLength
            var score = 2.0 + SureTypeEngine.boostValue(u.count)
            score += exact ? 4.0 : -0.7 * Float(u.keys.count - seqLength)
            if exact && u.word == mruWord { score += 8.0 }
            insert(Scored(text: u.word, score: score), into: &main, limit: limit)
        }

        // 4) Autocorreccion (teclas vecinas, intercambiadas o de mas). Va siempre al final de la lista.
        var fuzzy: [Scored] = []
        if includeFuzzy && explicit.isEmpty && seqLength >= 2 {
            var known = Set<String>()
            for item in main { known.insert(item.text) }
            fuzzy = fuzzyCandidates(seqBytes, d: d, limit: main.count < 6 ? 5 : 3, exclude: known)
        }

        var words: [String] = []
        var seen = Set<String>()
        for item in main + fuzzy {
            if seen.insert(item.text).inserted {
                words.append(item.text)
            }
        }

        if words.isEmpty {
            return Suggestions(words: [literal], isLiteral: true)
        }
        // Las letras literales siempre se pueden alcanzar rotando hasta el final.
        if explicit.isEmpty && !seen.contains(literal) {
            words.append(literal)
        }
        return Suggestions(words: words, isLiteral: false)
    }

    private func fuzzyCandidates(_ seqBytes: [UInt8], d: LanguageData, limit: Int, exclude: Set<String>) -> [Scored] {
        var variants = Set<[UInt8]>()

        // Tecla vecina por error
        for i in 0..<seqBytes.count {
            let c = Character(UnicodeScalar(seqBytes[i]))
            for n in KeyMap.neighbors[c] ?? [] {
                var v = seqBytes
                v[i] = n.asciiValue ?? v[i]
                variants.insert(v)
            }
        }
        // Dos teclas intercambiadas
        if seqBytes.count >= 2 {
            for i in 0..<(seqBytes.count - 1) {
                if seqBytes[i] == seqBytes[i + 1] { continue }
                var v = seqBytes
                v.swapAt(i, i + 1)
                variants.insert(v)
            }
        }
        // Una tecla de mas
        if seqBytes.count >= 3 {
            for i in 0..<seqBytes.count {
                var v = seqBytes
                v.remove(at: i)
                variants.insert(v)
            }
        }
        variants.remove(seqBytes)

        var result: [Scored] = []
        for v in variants {
            var j = d.dict.lowerBound(v)
            while j < d.dict.count && d.dict.seqLength(j) == v.count && d.dict.seqHasPrefix(j, v) {
                let idx = j
                j += 1
                let w = d.dict.word(idx)
                if exclude.contains(w) { continue }
                let score = d.dict.freqs[idx] + (boosts[idx] ?? 0) - 6.0
                insert(Scored(text: w, score: score), into: &result, limit: limit)
            }
        }
        return result
    }

    // MARK: Aprendizaje

    /// Suma un uso a la palabra elegida, al par (palabra anterior, palabra) y la fija
    /// como primera opcion de su secuencia exacta (como hacia el SureType real).
    /// Las palabras que no estan en el diccionario solo se aprenden si `allowNew` es true
    /// (cuando las deletreaste letra por letra).
    func learn(_ word: String, previous: String?, allowNew: Bool) {
        guard let d = data else { return }
        let w = word.trimmingCharacters(in: CharacterSet.whitespaces)
        if w.isEmpty { return }

        let idx = d.dict.indexOf(word: w)
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
            let keys = Array(KeyMap.keySequence(for: w).utf8)
            if !keys.isEmpty {
                userOnly.append(UserWord(word: w, keys: keys, count: 1))
            }
        }

        let seq = KeyMap.keySequence(for: w)
        if !seq.isEmpty {
            learnedBySeq[seq] = w
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
        if learnedBySeq.count > 5000 {
            // Se queda solo con las de palabras usadas mas de una vez
            learnedBySeq = learnedBySeq.filter { (learned[$0.value] ?? 0) > 1 }
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
        if let raw = try? JSONEncoder().encode(learnedBySeq) {
            defaults.set(raw, forKey: bySeqKey)
        }
    }
}
