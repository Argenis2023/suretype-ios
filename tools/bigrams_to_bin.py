#!/usr/bin/env python3
"""Convierte los bigramas de texto (tools/raw/bigram_XX.txt) al formato binario
que carga el teclado, apuntando a indices del diccionario binario.

Formato bigram_XX.bin (little-endian):
  magic "STB2" | prevCount u32 | followerTotal u32 |
  prevOffsets u32 x (prevCount+1)      (indice de elemento en followers)
  prevWordOffsets u32 x (prevCount+1)  (offset de bytes en prevBlob)
  followers: (wordIdx u32, weight f32) x followerTotal
  prevBlob utf8 (palabras anteriores ordenadas por bytes, para busqueda binaria)

El peso viene del puesto en la lista: 9.0 - 0.75*puesto, minimo 1.5.
Los seguidores que no estan en el diccionario se descartan.
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RES = ROOT.parent / "Keyboard" / "Resources"
RAW = ROOT / "raw"


def read_dict_bin(path: Path):
    data = path.read_bytes()
    assert data[:4] == b"STD2"
    n = struct.unpack_from("<I", data, 4)[0]
    off = 8
    seq_offsets = struct.unpack_from(f"<{n + 1}I", data, off)
    off += 4 * (n + 1)
    word_offsets = struct.unpack_from(f"<{n + 1}I", data, off)
    off += 4 * (n + 1)
    off += 4 * n  # freqs
    seq_blob_len = seq_offsets[-1]
    word_blob = data[off + seq_blob_len:]
    index = {}
    for i in range(n):
        w = word_blob[word_offsets[i]:word_offsets[i + 1]].decode("utf-8")
        index.setdefault(w.lower(), i)
    return index


def build(lang: str):
    dict_index = read_dict_bin(RES / f"dict_{lang}.bin")
    src = RAW / f"bigram_{lang}.txt"
    table = {}
    for line in src.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        prev = parts[0]
        followers = []
        for rank, w in enumerate(parts[1].split(" ")):
            idx = dict_index.get(w.lower())
            if idx is None:
                continue
            weight = max(9.0 - 0.75 * rank, 1.5)
            followers.append((idx, weight))
        if followers:
            table[prev] = followers

    prevs = sorted(table, key=lambda p: p.encode("utf-8"))
    prev_blob = bytearray()
    prev_word_offsets = [0]
    prev_offsets = [0]
    followers_flat = []
    for p in prevs:
        prev_blob += p.encode("utf-8")
        prev_word_offsets.append(len(prev_blob))
        followers_flat.extend(table[p])
        prev_offsets.append(len(followers_flat))

    out = RES / f"bigram_{lang}.bin"
    with out.open("wb") as f:
        f.write(b"STB2")
        f.write(struct.pack("<I", len(prevs)))
        f.write(struct.pack("<I", len(followers_flat)))
        f.write(struct.pack(f"<{len(prevs) + 1}I", *prev_offsets))
        f.write(struct.pack(f"<{len(prevs) + 1}I", *prev_word_offsets))
        for idx, weight in followers_flat:
            f.write(struct.pack("<If", idx, weight))
        f.write(bytes(prev_blob))
    print(f"{lang}: {len(prevs)} palabras anteriores, {len(followers_flat)} pares -> {out}")


if __name__ == "__main__":
    for lang in sys.argv[1:] or ["es", "en"]:
        build(lang)
