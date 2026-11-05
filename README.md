# Etymon

An iOS app that reads the words around you — text seen by the camera, speech heard by the
microphone — and surfaces the network of human languages underneath them: shared roots,
lines of inheritance, borrowings that cross-pollinated between languages, cognates.

A pharmacy sign in Milan links to Greek *φάρμακον*; *padre* on a poster reaches Latin
*pater*, Proto-Indo-European *\*ph₂tḗr*, and from there English *father*, German *Vater*,
French *père*.

## Status

- [x] **Data pipeline** — Wiktionary etymologies → typed SQLite graph (`pipeline/`)
- [x] **Backend API** — scene words in, shared roots and same-meaning links out (`backend/`)
- [x] **iOS MVP** — camera / photo / typed text → text recognition → API → network drawn
  over the picture and live video, plus a graph view (`ios/`)
- [ ] Field testing on a device; offline cache of common words
- [ ] Speech input
- [ ] AR mode (words anchored in space, linked to floating roots)
- [ ] Saved sessions / personal map of collected words

## Getting started

Everything runs locally on a Mac: the **pipeline** builds the etymology database once, the
**backend** serves it, and the **iOS app** (simulator or iPhone) talks to the backend.

### Prerequisites

- macOS with **Xcode 16 or later** (from the App Store), opened once so it installs its
  components, and selected as the active developer directory:
  `sudo xcode-select -s /Applications/Xcode.app`
- An iOS simulator runtime: Xcode → Settings → Components (the steps below use
  *iPhone 17*; any recent iPhone simulator works — list them with
  `xcrun simctl list devices available`)
- **Python 3.11+** (`python3 --version`)
- [Homebrew](https://brew.sh), for **XcodeGen**: `brew install xcodegen`
- About **15 GB free disk** while building the data (raw dumps are downloaded one at a
  time and deleted after slimming); the finished database is about 1 GB

### 1. Build the database (once)

```sh
cd pipeline
python3 -m venv .venv
.venv/bin/pip install wordfreq
.venv/bin/python fetch_languages.py
.venv/bin/python fetch.py English Italian Spanish French German Latin "Ancient Greek"
.venv/bin/python fetch.py "Proto-Indo-European" "Proto-Germanic" "Proto-West Germanic" \
    "Proto-Italic" "Proto-Celtic" "Proto-Slavic" "Proto-Balto-Slavic" "Proto-Indo-Iranian" \
    "Old English" "Old Saxon" "Old High German" "Middle High German" "Old Norse" "Gothic" \
    "Middle English" "Old French" "Middle French" "Old Spanish" "Old Irish" \
    "Old Church Slavonic" Sanskrit
.venv/bin/python build_graph.py
.venv/bin/python build_meanings.py
```

Downloading takes from under an hour to a few hours depending on kaikki.org's speed
(English alone is 3.3 GB); downloads resume if interrupted, and languages already
fetched are skipped. `build_graph.py` takes about 10 minutes. The result is
`pipeline/data/etymon.sqlite`. Check it:

```sh
.venv/bin/python connect.py it padre en paternalistic   # meet at Latin pater
```

### 2. Run the backend

In its own terminal (leave it running; **Ctrl+C** stops it):

```sh
cd backend
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn httpx pytest
.venv/bin/uvicorn app:app --port 8000
```

Check it: `curl localhost:8000/health` → `{"ok":true,...}`; interactive API docs at
<http://localhost:8000/docs>.

### 3. Run the app in the simulator

```sh
cd ios
xcodegen generate          # creates Etymon.xcodeproj from project.yml; rerun after pulling
open Etymon.xcodeproj
```

In Xcode choose the **Etymon** scheme and an **iPhone 17** simulator, then **⌘R**.

Or from the terminal:

```sh
cd ios
xcodegen generate
xcodebuild -project Etymon.xcodeproj -scheme Etymon \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl boot "iPhone 17"; open -a Simulator
xcrun simctl install "iPhone 17" build/Build/Products/Debug-iphonesimulator/Etymon.app
xcrun simctl launch "iPhone 17" com.ranierovirgilio.etymon
```

The simulator has no camera, so use **Photo** or **Type**:

- **Photo** — pick an image with text. Add your own to the simulator's library by
  dragging it onto the Simulator window, or
  `xcrun simctl addmedia "iPhone 17" ios/EtymonUITests/sign.png` (a sample pharmacy sign).
- **Type** — edit the words and press **Connect**.

Launch arguments, for demos (Xcode: Product → Scheme → Edit Scheme → Run → Arguments):
`-demo` connects the sample typed words at launch; `-source photo -photo <path>` opens a
photo file directly.

### 4. Run the app on an iPhone

The live camera overlay only works on a real device.

1. Connect the iPhone by cable (or same Wi-Fi with pairing set up) and enable
   **Developer Mode** on it (Settings → Privacy & Security).
2. In Xcode select the **Etymon** target → **Signing & Capabilities**, tick *Automatically
   manage signing* and pick your **Team** (a free Apple ID works). If the bundle id is
   taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` and rerun
   `xcodegen generate`.
3. Start the backend so the phone can reach it over the network:
   `.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000`
4. Choose the iPhone as the run destination and press **⌘R**. On first launch allow
   camera and local-network access.
5. In the app's **Settings** (gear), set the server to your Mac's address, e.g.
   `http://192.168.1.20:8000` (find it with `ipconfig getifaddr en0`). Phone and Mac must
   be on the same network.

### 5. Run the tests

With the backend running, from the repository root:

```sh
(cd backend && .venv/bin/pytest -q)                     # API
(cd ios && xcodebuild -project Etymon.xcodeproj -scheme Etymon \
  -destination 'platform=iOS Simulator,name=iPhone 17' test)  # app unit + UI tests
```

The UI tests drive the app in the simulator like a user (photo → overlay → detail sheets
→ graph). To keep their screenshots, add `TEST_RUNNER_ETYMON_SHOTS=/some/folder` in front
of the `xcodebuild` command.

### Stopping and troubleshooting

- **Stop the backend**: Ctrl+C in its terminal, or `pkill -f "uvicorn app:app"`.
- **"Address already in use"** when starting the backend: one is already running on
  port 8000 — use it, or stop it with `kill $(lsof -ti tcp:8000)`.
- **Error banner in the app / nothing connects**: the backend isn't running, or the server
  address in the app's Settings is wrong (simulator: `http://localhost:8000`).
- **`database not found`** from `/health`: build the database (step 1), or point the
  backend at it with `ETYMON_DB=/path/to/etymon.sqlite`.
- **`xcodebuild` requires Xcode** / no iOS SDK: run the `xcode-select` command above.
- **Unable to find destination "iPhone 17"**: use a simulator you have, from
  `xcrun simctl list devices available`.

## iOS app

SwiftUI, iOS 17+, in `ios/`. The Xcode project is generated from `ios/project.yml` by
XcodeGen and is not checked in. Setup and running: see [Getting started](#getting-started).

The network is drawn **over the picture and the live video**, anchored to the words: each
word is outlined where it is, shared ancestors float above the words they join (solid
curves), and words with the same meaning are joined by dashed arcs ("= open"). The camera
reads the frame carefully about once a second (new words, language) and quickly ~10 times a
second in between to re-locate known words, so the overlay moves with the video; words that
leave the frame fade out. **Hold** keeps the current words while still tracking them.
**Graph** shows the same network as a diagram (the default view for typed words); **Full
paths** shows every step; tapping an ancestor opens both chains and the deeper line to the
root, tapping a word its own lineage.

## Backend

FastAPI over the SQLite graph, in `backend/`: the app sends the words it recognised and
gets the network back. Setup and running: see [Getting started](#getting-started).

`POST /scene` — the words seen together (returns shared-ancestry `connections` and
same-meaning `semantic` links), optionally with the scene's likely language:

```json
{"lang": "it", "words": [{"text": "padre"}, {"text": "paternalistic", "lang": "en"}]}
```

returns each word's resolved terms, and for every pair that shares ancestry the nearest
meeting point (*pater*), both paths to it, and the `deeper` chain above it
(*\*patēr* → *\*ph₂tḗr* → root *\*peh₂-*), plus a `nodes` table for labels.
`GET /word?text=padri&lang=it` gives one word's lineage. `ETYMON_DB` points at the database
(default `pipeline/data/etymon.sqlite`).

## Data pipeline

Sources:
- [kaikki.org](https://kaikki.org) / [wiktextract](https://github.com/tatuylonen/wiktextract)
  machine-readable Wiktionary dumps — etymology templates give typed relationships
- Wiktionary's language, family and etymology-language tables (`Module:JSON data`)
- [wordfreq](https://github.com/rspeer/wordfreq) for pruning to words people actually meet

Steps: see [Getting started](#getting-started). The scripts:

| script | does |
|---|---|
| `fetch_languages.py` | Wiktionary's language, family and etymology-language tables |
| `fetch.py <Language>...` | downloads kaikki.org dumps and keeps the fields the graph needs |
| `build_graph.py` | builds `data/etymon.sqlite` from the slimmed dumps |
| `build_meanings.py` | adds same-meaning links (`meaning` table) |
| `query.py it padri` | explore one word |
| `connect.py it padre en paternalistic` | what two words have in common |
| `export_mobile.py` | a pruned, app-sized copy of the graph (for a future offline mode) |

The historical and reconstructed languages matter: their entries list descendants
across branches, which is what surfaces shared roots (PIE *\*ph₂tḗr* → Latin *pater*,
Proto-Germanic *\*fadēr*, Sanskrit *pitṛ́*...).

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

Descendant lists on historical and reconstructed entries become links too (inferred:
a word's own stated etymology still wins).

`meaning(term, key)` holds English meaning keys for semantic links: non-English entries
are defined in English (it *aperto*: "open"), English words key on themselves, so words
sharing a key are translations (it *aperta* = en *open* = de *offen*), whether or not
they share an origin.

`inferred=1` marks links read off an etymology chain ("from X, from Y") rather than
stated on X's own entry. `form(lang, form, lemma)` maps inflected forms to lemmas
(*padri* → *padre*). `language` / `family` give each code a name and place in the
family tree.

Etymological data from Wiktionary is licensed CC BY-SA 4.0; the bundled database must
carry that attribution.
