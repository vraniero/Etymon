# Etymon

An iOS app that reads the words around you — text seen by the camera, speech heard by the
microphone — and surfaces the network of human languages underneath them: shared roots,
lines of inheritance, borrowings that cross-pollinated between languages, cognates.

A pharmacy sign in Milan links to Greek *φάρμακον*; *padre* on a poster reaches Latin
*pater*, Proto-Indo-European *\*ph₂tḗr*, and from there English *father*, German *Vater*,
French *père*.

## Status

- [x] **Data pipeline** — Wiktionary etymologies → typed SQLite graph (`pipeline/`)
- [x] **Backend API** — scene words in, shared-ancestry network out (`backend/`)
- [x] **iOS MVP** — camera / photo / typed text → text recognition → API → 2D network view (`ios/`)
- [ ] Field testing on a device; offline cache of common words
- [ ] Speech input
- [ ] AR mode (words anchored in space, linked to floating roots)
- [ ] Saved sessions / personal map of collected words

## iOS app

SwiftUI, iOS 17+. The Xcode project is generated from `ios/project.yml`:

```sh
brew install xcodegen
cd ios && xcodegen generate && open Etymon.xcodeproj
```

Run the backend first; the simulator reaches it at `http://localhost:8000` (change it in the
app's Settings — on a phone use the Mac's address and start uvicorn with `--host 0.0.0.0`).
The simulator has no camera: use **Photo** or **Type**; launching with `-demo` connects the
sample text at once. Tests: `xcodebuild -scheme Etymon -destination 'platform=iOS Simulator,name=iPhone 17' test`.

Words read in a scene accumulate (up to 20), the scene's language is detected on-device,
and each group of related words is drawn under the ancestor it shares; **Full paths** shows
every step, and tapping a meeting point opens both chains and the deeper line to the root.

## Backend

The graph lives server-side; the app sends the words it recognised and gets the network back.

```sh
cd backend
python3 -m venv .venv && .venv/bin/pip install fastapi uvicorn httpx pytest
.venv/bin/uvicorn app:app --reload          # http://localhost:8000/docs
.venv/bin/pytest -q
```

`POST /scene` — the words seen together, optionally with the scene's likely language:

```json
{"lang": "it", "words": [{"text": "padre"}, {"text": "paternalistic", "lang": "en"}]}
```

returns each word's resolved terms, and for every pair that shares ancestry the nearest
meeting point (*pater*), both paths to it, and the `deeper` chain above it
(*\*patēr* → *\*ph₂tḗr* → root *\*peh₂-*), plus a `nodes` table for labels.
`GET /word?text=padri&lang=it` gives one word's lineage. `ETYMON_DB` points at the database
(default `pipeline/data/etymon.sqlite`).

Two-word connections can also be explored from the shell:
`pipeline/.venv/bin/python pipeline/connect.py it padre en paternalistic`.

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
