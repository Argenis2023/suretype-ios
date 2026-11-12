import Foundation

// Banco de pruebas del motor: mide tiempos por pulsacion y acierto de la primera candidata.
// Uso: bench RUTA_RECURSOS RUTA_TEST_ES RUTA_TEST_EN

func now() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return Double(t.tv_sec) * 1000.0 + Double(t.tv_nsec) / 1_000_000.0
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("faltan argumentos")
    exit(1)
}
guard let bundle = Bundle(path: args[1]) else {
    print("no se pudo abrir \(args[1])")
    exit(1)
}

func run(_ lang: Language, _ testPath: String) {
    let t0 = now()
    let engine = SureTypeEngine(language: lang, bundle: bundle, defaults: UserDefaults(suiteName: "bench-\(lang.rawValue)")!)
    var ready = false
    engine.whenReady { ready = true }
    // whenReady usa la cola principal: se vacia aqui
    while !ready { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    let loadMs = now() - t0
    print("[\(lang.rawValue)] carga del diccionario: \(String(format: "%.0f", loadMs)) ms")

    guard let text = try? String(contentsOfFile: testPath, encoding: .utf8) else {
        print("sin archivo de prueba")
        return
    }
    let words = text.split(separator: "\n").map { String($0) }

    var perKey: [Double] = []
    var perKeyFuzzy: [Double] = []
    var hits = 0
    var inDict = 0
    var total = 0
    var misses: [String: Int] = [:]

    for w in words {
        let seq = KeyMap.keySequence(for: w)
        if seq.count != w.count { continue }
        total += 1
        var slots: [Slot] = []
        var last: Suggestions?
        for ch in seq {
            slots.append(Slot.key(ch))
            let a = now()
            last = engine.suggest(slots, previous: nil, includeFuzzy: false)
            perKey.append(now() - a)
        }
        let b = now()
        _ = engine.suggest(slots, previous: nil, includeFuzzy: true)
        perKeyFuzzy.append(now() - b)

        if let l = last {
            if l.words.first == w { hits += 1 }
            if l.words.contains(w) { inDict += 1 }
            if l.words.first != w {
                misses["\(w)->\(l.words.first ?? "?")", default: 0] += 1
            }
        }
    }
    perKey.sort()
    perKeyFuzzy.sort()
    func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
    print("[\(lang.rawValue)] palabras: \(total)  primera candidata correcta: \(hits) (\(String(format: "%.1f", 100.0 * Double(hits) / Double(max(total, 1))))%)  correcta entre las 10: \(String(format: "%.1f", 100.0 * Double(inDict) / Double(max(total, 1))))%")
    print("[\(lang.rawValue)] suggest sin autocorreccion (ms): media \(String(format: "%.3f", perKey.reduce(0, +) / Double(max(perKey.count, 1))))  p95 \(String(format: "%.3f", pct(perKey, 0.95)))  max \(String(format: "%.3f", perKey.last ?? 0))")
    print("[\(lang.rawValue)] suggest con autocorreccion (ms): media \(String(format: "%.3f", perKeyFuzzy.reduce(0, +) / Double(max(perKeyFuzzy.count, 1))))  p95 \(String(format: "%.3f", pct(perKeyFuzzy, 0.95)))  max \(String(format: "%.3f", perKeyFuzzy.last ?? 0))")
    let top = misses.sorted { $0.value > $1.value }.prefix(15).map { $0.key }
    print("[\(lang.rawValue)] fallos: \(top.joined(separator: ", "))")
}

run(Language.es, args[2])
run(Language.en, args[3])
