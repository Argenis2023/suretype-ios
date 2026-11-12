#!/usr/bin/env python3
"""Genera Keyboard/Resources/bigram_es.txt y bigram_en.txt (palabra anterior -> palabras que suelen seguir).

Necesita las colecciones de texto de NLTK descargadas en una carpeta (zip desde
https://github.com/nltk/nltk_data/tree/gh-pages/packages/corpora) y `pip install nltk`:
cess_esp, conll2002, europarl_raw, brown, reuters, webtext, nps_chat.

Uso:  python tools/build_bigrams.py RUTA/A/nltk_data/corpora
Solo se usan palabras que existen en dict_es.txt / dict_en.txt.
"""
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RES = ROOT.parent / "Keyboard" / "Resources"
CORPORA = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("nltk_data/corpora")

SPLIT_END = re.compile(r"[.!?;:\n¡¿]+")
WORD = re.compile(r"[a-záéíóúüñ]+(?:'[a-z]+)?|[^\sa-z]", re.I)
CLITICS = {"n't", "'s", "'m", "'ll", "'re", "'ve", "'d", "'t"}


def nfc(s):
    return unicodedata.normalize("NFC", s)


def load_dict(lang):
    m = {}
    for line in (RES / f"dict_{lang}.txt").read_text(encoding="utf-8").splitlines():
        _, disp, _ = line.split("\t")
        m[disp.lower()] = disp
    return m


def merge_clitics(tokens):
    out = []
    for t in tokens:
        t = nfc(t.lower())
        if t in CLITICS and out:
            prev = out[-1]
            if t == "n't" and prev == "ca":
                out[-1] = "can't"
            elif t == "n't" and prev == "wo":
                out[-1] = "won't"
            else:
                out[-1] = prev + t
        else:
            out.append(t)
    return out


def raw_sentences(text):
    for chunk in SPLIT_END.split(text):
        toks = WORD.findall(chunk)
        if toks:
            yield toks


def read_raw(folder, pattern):
    for p in sorted(Path(folder).glob(pattern)):
        yield from raw_sentences(p.read_text(encoding="utf-8", errors="ignore"))


def nltk_sents(kind):
    import nltk
    nltk.data.path.insert(0, str(CORPORA.parent))
    from nltk.corpus import cess_esp, conll2002, brown, reuters
    if kind == "cess":
        return cess_esp.sents()
    if kind == "conll":
        return (s for f in conll2002.fileids() if f.startswith("esp") for s in conll2002.sents(f))
    if kind == "brown":
        return brown.sents()
    if kind == "reuters":
        return [reuters.words()]  # sin segmentador: los puntos reinician la frase


def nps_posts():
    for p in sorted((CORPORA / "nps_chat").glob("*.xml")):
        for m in re.finditer(r">([^<>]{3,200})</", p.read_text(encoding="utf-8", errors="ignore")):
            yield from raw_sentences(m.group(1))


def sources(lang):
    if lang == "es":
        yield nltk_sents("cess")
        yield nltk_sents("conll")
        yield read_raw(CORPORA / "europarl_raw" / "spanish", "*.es")
    else:
        yield nltk_sents("brown")
        yield nltk_sents("reuters")
        yield read_raw(CORPORA / "europarl_raw" / "english", "*.en")
        yield read_raw(CORPORA / "webtext", "*.txt")
        yield nps_posts()


def build(lang):
    dmap = load_dict(lang)
    pairs = defaultdict(Counter)
    total_tokens = 0
    for source in sources(lang):
        for sent in source:
            prev = "<s>"
            for tok in merge_clitics(list(sent)):
                if tok in {".", "!", "?", ";", ":"}:
                    prev = "<s>"
                    continue
                if tok not in dmap:
                    prev = None
                    continue
                total_tokens += 1
                if prev:
                    pairs[prev][tok] += 1
                prev = tok
    rows = []
    for prev, nxt in pairs.items():
        total = sum(nxt.values())
        if total < 3:
            continue
        best = [(w, c) for w, c in nxt.most_common(6) if c >= 2]
        if best:
            rows.append((total, prev, [dmap[w] for w, _ in best]))
    rows.sort(key=lambda r: -r[0])
    rows = rows[:9000]
    rows.sort(key=lambda r: r[1])
    out = RES / f"bigram_{lang}.txt"
    with out.open("w", encoding="utf-8", newline="\n") as f:
        for _, prev, words in rows:
            f.write(prev + "\t" + " ".join(words) + "\n")
    print(f"{lang}: {total_tokens} palabras leidas, {len(rows)} palabras con sucesoras -> {out}")
    return dict((p, w) for _, p, w in rows)


if __name__ == "__main__":
    for lang in ("es", "en"):
        table = build(lang)
        for key in ("<s>", "por", "de", "que", "estoy", "gracias", "buenos", "i", "thank", "how", "i'm"):
            if key in table:
                print("  ", key, "->", table[key])
