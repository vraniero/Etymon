# Etymon

An iOS app that reads the words around you — text seen by the camera, speech heard by the
microphone — and surfaces the network of human languages underneath them: shared roots,
lines of inheritance, borrowings that cross-pollinated between languages, cognates.

A pharmacy sign in Milan links to Greek *φάρμακον*; *padre* on a poster reaches Latin
*pater*, Proto-Indo-European *\*ph₂tḗr*, and from there English *father*, German *Vater*,
French *père*.

## Status

- [x] **Data pipeline** — Wiktionary etymologies → typed SQLite graph (`pipeline/`)
- [ ] iOS MVP — camera → text recognition → lookup → 2D network view
- [ ] Speech input
- [ ] AR mode (words anchored in space, linked to floating roots)
- [ ] Saved sessions / personal map of collected words

## Data pipeline

Sources:
- [kaikki.org](https://kaikki.org) / [wiktextract](https://github.com/tatuylonen/wiktextract)
  machine-readable Wiktionary dumps — etymology templates give typed relationships
- Wiktionary's language, family and etymology-language tables (`Module:JSON data`)
- [wordfreq](https://github.com/rspeer/wordfreq) for pruning to words people actually meet

```sh
cd pipeline
python3 -m venv .venv && .venv/bin/pip install wordfreq
.venv/bin/python fetch_languages.py
.venv/bin/python fetch.py English Italian Spanish French German Latin "Ancient Greek"
.venv/bin/python build_graph.py        # -> data/etymon.sqlite (full graph)
.venv/bin/python export_mobile.py      # -> data/etymon-mobile.sqlite (app bundle)
.venv/bin/python query.py it padri     # explore a word
```

`fetch.py` downloads each raw dump (~0.6–3.4 GB, resumable), keeps only the fields the
graph needs, and deletes the raw file.

### Graph model

`term(lang, word, gloss, etym, zipf)` nodes and `edge(src, dst, kind, inferred)` edges,
pointing from a word to its source:

| kind | meaning | example |
|---|---|---|
| `inherited` | native line of descent | it *padre* → la *pater* |
| `borrowed` | taken from another language | it *caffè* → ota *قهوه* |
| `learned` | learned borrowing from a classical language | |
| `calque` | loan translation | de *Wolkenkratzer* → en *skyscraper* |
| `semantic_loan` | meaning borrowed onto an existing word | |
| `derived` | unspecified "from X" | |
| `root` | reconstructed root | it *padre* → ine-pro *\*peh₂-* |
| `component` | morpheme / compound part | |
| `cognate` | shares an ancestor (undirected) | |
| `doublet` | same ancestor, different paths into one language | |

`inferred=1` marks links read off an etymology chain ("from X, from Y") rather than
stated on X's own entry. `form(lang, form, lemma)` maps inflected forms to lemmas
(*padri* → *padre*). `language` / `family` give each code a name and place in the
family tree.

Etymological data from Wiktionary is licensed CC BY-SA 4.0; the bundled database must
carry that attribution.
