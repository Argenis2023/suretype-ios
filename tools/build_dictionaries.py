#!/usr/bin/env python3
"""Genera Keyboard/Resources/dict_es.txt y dict_en.txt.

Formato de cada linea:  SECUENCIA_DE_TECLAS <TAB> palabra <TAB> frecuencia
Las lineas van ordenadas por SECUENCIA_DE_TECLAS (orden ASCII) para que el
teclado pueda buscar por prefijo con busqueda binaria.

La tabla de teclas debe ser identica a KeyMap en SureTypeEngine.swift.

Fuente de frecuencias: hermitdave/FrequencyWords (CC BY-SA 4.0), basada en OpenSubtitles.
"""
import math
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "raw"
OUT = ROOT.parent / "Keyboard" / "Resources"

KEY_LETTERS = {
    "Q": "qw", "E": "er", "T": "ty", "U": "ui", "O": "op",
    "A": "as", "D": "df", "G": "gh", "J": "jk", "L": "lñ",
    "Z": "zx", "C": "cv", "B": "bn", "M": "m",
}
LETTER_TO_KEY = {c: k for k, letters in KEY_LETTERS.items() for c in letters}
LETTER_TO_KEY.update({"á": "A", "é": "E", "í": "U", "ó": "O", "ú": "U", "ü": "U"})


def key_sequence(word: str) -> str:
    return "".join(LETTER_TO_KEY[c] for c in word.lower() if c in LETTER_TO_KEY)


def nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


def read_list(path: Path) -> dict:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ")
        if len(parts) != 2:
            continue
        w, c = nfc(parts[0].lower()), int(parts[1])
        out[w] = out.get(w, 0) + c
    return out


ES_RE = re.compile(r"^[a-záéíóúüñ]+$")
EN_RE = re.compile(r"^[a-z]+$")
ES_VOWELS = set("aeiouáéíóúü")
EN_VOWELS = set("aeiouy")

ES_ONE = set("ayoeu")
EN_ONE = set("ai")
ES_TWO = set("de no la el es en lo un me se te mi si su yo tu al le ya ha he va oh ti ir ni eh ve ah os vi da ok di uh ay fe ja jo po pa tv sr mm".split())
EN_TWO = set("to it of is in we me he my on do no be so go if up at oh as an us or by am uh ok hi ah um mr ya eh tv yo ow aw dr hm mm ma pa".split())

# Fragmentos de contracciones que el corpus separa y que no son palabras
EN_STEMS = set("don didn doesn isn wasn couldn wouldn shouldn aren haven hasn weren ain mustn needn hadn ll re ve".split())


def clean(words: dict, lang: str, other: dict) -> dict:
    rx, vowels = (ES_RE, ES_VOWELS) if lang == "es" else (EN_RE, EN_VOWELS)
    one, two = (ES_ONE, ES_TWO) if lang == "es" else (EN_ONE, EN_TWO)
    out = {}
    for w, c in words.items():
        if not rx.match(w):
            continue
        if lang == "en" and w in EN_STEMS:
            continue
        if len(w) > 20:
            continue
        if len(w) == 1 and w not in one:
            continue
        if len(w) == 2 and w not in two:
            continue
        if len(w) >= 3 and not (set(w) & vowels):
            continue
        if re.search(r"(.)\1\1", w):
            continue
        # palabras del otro idioma que se cuelan en la lista (ej. "the" en espanol)
        oc = other.get(w, 0)
        if c < 150_000 and oc > 5 * c:
            continue
        out[w] = c
    if lang == "es":
        # Formas con tilde mal escritas en los subtitulos ("vámos", "díme", "cúando"):
        # se descartan si su version sin tilde existe y es mucho mas frecuente.
        for w in list(out):
            plain = fold_accents(w)
            if plain != w and plain in out and out[w] < 0.03 * out[plain]:
                del out[w]
    return out


def fold_accents(w: str) -> str:
    return w.translate(str.maketrans("áéíóúü", "aeiouu"))


ES_EXTRA = {
    # coloquiales y uso diario en Chile
    "po": 40000, "cachai": 30000, "weon": 30000, "weón": 30000, "wea": 25000, "weá": 25000,
    "bacán": 20000, "fome": 20000, "pololo": 20000, "polola": 20000, "luca": 15000, "lucas": 20000,
    "carrete": 15000, "cabro": 15000, "caleta": 15000, "altiro": 15000, "pega": 30000, "filo": 15000,
    # tecnologia
    "whatsapp": 40000, "instagram": 30000, "wifi": 30000, "email": 30000, "online": 30000,
    "app": 40000, "apps": 25000, "software": 30000, "hardware": 25000, "link": 30000, "chat": 40000,
    "github": 20000, "python": 20000, "datos": 200000,
}

EN_EXTRA = {
    "whatsapp": 40000, "instagram": 30000, "wifi": 30000, "email": 60000, "online": 60000,
    "app": 60000, "apps": 30000, "software": 40000, "hardware": 30000, "github": 20000,
}

# Contracciones: el corpus las parte en trozos ("don" + "'t"), asi que se asignan a mano
EN_CONTRACTIONS = {
    "don't": 4_160_000, "can't": 1_300_000, "didn't": 1_100_000, "doesn't": 470_000, "isn't": 430_000,
    "wasn't": 310_000, "wouldn't": 290_000, "haven't": 260_000, "couldn't": 230_000, "aren't": 180_000,
    "shouldn't": 120_000, "weren't": 90_000, "hasn't": 70_000, "won't": 400_000, "ain't": 160_000,
    "i'm": 4_380_000,
    "it's": 5_000_000, "that's": 2_400_000, "what's": 1_300_000, "he's": 1_100_000, "there's": 900_000,
    "let's": 900_000, "she's": 600_000, "here's": 400_000, "who's": 300_000, "how's": 300_000, "where's": 200_000,
    "you're": 2_800_000, "we're": 700_000, "they're": 500_000,
    "i'll": 1_000_000, "you'll": 600_000, "we'll": 500_000, "it'll": 250_000, "they'll": 200_000, "he'll": 130_000, "she'll": 90_000, "that'll": 60_000,
    "i've": 900_000, "you've": 500_000, "we've": 300_000, "they've": 150_000, "could've": 60_000, "would've": 60_000, "should've": 50_000,
    "i'd": 400_000, "you'd": 200_000, "he'd": 120_000, "we'd": 120_000, "they'd": 80_000, "she'd": 60_000,
}


def en_display(w: str) -> str:
    if w == "i":
        return "I"
    if w.startswith("i'"):
        return "I" + w[1:]
    return w


def build(lang: str):
    es = read_list(RAW / "es_50k.txt")
    en = read_list(RAW / "en_50k.txt")
    words, other = (es, en) if lang == "es" else (en, es)
    cleaned = clean(words, lang, other)
    extra = ES_EXTRA if lang == "es" else EN_EXTRA
    for w, c in extra.items():
        cleaned[nfc(w)] = max(cleaned.get(nfc(w), 0), c)
    rows = []
    if lang == "en":
        for w, c in EN_CONTRACTIONS.items():
            keys = key_sequence(w)
            rows.append((keys, en_display(w), c))
    for w, c in cleaned.items():
        keys = key_sequence(w)
        if not keys:
            continue
        disp = en_display(w) if lang == "en" else w
        rows.append((keys, disp, c))
    # tomar las N mas frecuentes y ordenar por secuencia de teclas
    rows.sort(key=lambda r: -r[2])
    rows = rows[:45000]
    rows.sort(key=lambda r: (r[0], -r[2]))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"dict_{lang}.txt"
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for keys, disp, c in rows:
            f.write(f"{keys}\t{disp}\t{c}\n")
    print(f"{lang}: {len(rows)} palabras -> {path}")
    return rows


def preview(rows, words):
    for w in words:
        seq = key_sequence(w)
        cands = []
        for keys, disp, c in rows:
            if keys.startswith(seq):
                score = math.log(c + 1) + (3 if len(keys) == len(seq) else 0)
                cands.append((score, disp))
        cands.sort(reverse=True)
        print(f"  {w:12s} {seq:10s} -> {[d for _, d in cands[:6]]}")


if __name__ == "__main__":
    es_rows = build("es")
    en_rows = build("en")
    if "--preview" in sys.argv:
        print("Prueba ES:")
        preview(es_rows, ["hola", "gracias", "como", "estas", "esta", "mañana", "pero", "porque", "que", "tambien", "cachai", "ho", "con", "para", "quiero", "estás"])
        print("Prueba EN:")
        preview(en_rows, ["hello", "the", "dont", "don", "thanks", "im", "what", "that", "because", "you"])
