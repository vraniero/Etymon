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
- [x] **Talk** — a separate tab: a 3D space a conversation grows in real time. The
  microphone streams to the backend (`backend/listen.py`: Whisper per utterance, speaker
  embeddings to tell voices apart); each word said appears in its speaker's colour with its
  tree of ancestors, and connects where trees meet or meanings match — with a chime
  (sound can be turned off) (`ios/Etymon/TalkSession.swift`, `TalkView.swift`, `Chimes.swift`).
  `-talkdemo` launch argument plays a scripted conversation (simulator, screenshots)
- [ ] Field testing on a device (in progress on an iPhone)
- [x] **AR mode** — words anchored where they are in the room, shared roots floating
  above them (`ios/Etymon/ARInput.swift`); needs a device with world tracking
- [x] **Saved network** — scenes saved on the phone with their network, picture, object,
  place and time; a list and map of them; all of them explorable together in 3D, offline
  (`ios/Etymon/SavedScene.swift`, `LibraryViews.swift`, `OfflineCache.swift`)
- [x] **Large scenes** — up to 200 words per scene in the app (500 accepted by the backend)

## Getting started

Everything runs locally on a Mac: the **pipeline** builds the etymology database once, the
**backend** serves it, and the **iOS app** (simulator or iPhone) talks to the backend.

### Prerequisites

- macOS with **Xcode** (from the App Store), opened once so it installs its components,
  and selected as the active developer directory:
  `sudo xcode-select -s /Applications/Xcode.app`. To run on an iPhone, Xcode must
  support the **phone's iOS version** (an iPhone on iOS 27 needs Xcode 27) — check with
  `xcodebuild -showsdks`.
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
# Central and Eastern Europe: Cyrillic and Latin-script Slavic, Romanian, Hungarian, Baltic
.venv/bin/python fetch.py Russian Ukrainian Belarusian Bulgarian Macedonian "Serbo-Croatian" \
    Polish Czech Slovak Slovene Romanian Hungarian Estonian Lithuanian Latvian \
    "Old East Slavic" "Old Ruthenian" "Old Polish" "Old Czech" "Old Slovak" \
    "Proto-Uralic" "Proto-Finnic" "Proto-Turkic"
.venv/bin/python build_graph.py
.venv/bin/python build_meanings.py
.venv/bin/python geo.py        # where each language was spoken, for the map view
```

Downloading takes from under an hour to a few hours depending on kaikki.org's speed
(English alone is 3.3 GB, the Central and Eastern European set about 5 GB more); downloads resume if interrupted, and languages already
fetched are skipped. `build_graph.py` takes about 10 minutes. The result is
`pipeline/data/etymon.sqlite`. Check it:

```sh
.venv/bin/python connect.py it padre en paternalistic   # meet at Latin pater
```

### 2. Run the backend

Set it up once:

```sh
cd backend
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn httpx pytest websockets
```

For **Talk** (listening to conversations) add the speech models — Apple Silicon only; about
2 GB on first use (Whisper large-v3-turbo, an ECAPA speaker model), downloaded the first
time the phone starts listening:

```sh
.venv/bin/pip install mlx-whisper speechbrain soundfile
```

`websockets` is what lets uvicorn accept the phone's audio stream (`/listen`); without it
the phone's microphone button reports the server lost. Each utterance appears in the
monitor with its persona (`P1*` = a new voice) and language.

Then run it in its own terminal window and leave it running (**Ctrl+C** stops it):

```sh
cd backend
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000 --no-access-log
```

`--host 0.0.0.0` makes it reachable from an iPhone on the same Wi-Fi (for the simulator
alone, `localhost` is enough); `--no-access-log` leaves just the monitor output.

Check it: `curl localhost:8000/health` → `{"ok":true,...}`; interactive API docs at
<http://localhost:8000/docs>.

**The terminal is a live monitor**: each scene the phone or simulator sends, and each
word tapped, is printed as it happens — see [Backend monitor](#backend-monitor). To keep
that output in a file, or run the backend in the background, see
[Backend logs](#backend-logs).

**Stop it:**

- Started in a terminal window: press **Ctrl+C** there. It finishes the request in
  progress and exits (`Application shutdown complete.`).
- Started in the background, or you've lost the window: `pkill -f "uvicorn app:app"`.
  If that finds nothing but port 8000 is still taken, stop whatever holds the port:
  `kill $(lsof -ti tcp:8000)`.
- Check it's down: `curl localhost:8000/health` → *Connection refused*. Check what's still
  running: `pgrep -fl "uvicorn app:app"` (no output = nothing running).

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

Launch arguments (Xcode: Product → Scheme → Edit Scheme → Run → Arguments):

| argument | does |
|---|---|
| `-demo` | connects the sample typed words at launch |
| `-source ar\|photo\|type` | opens in that mode (`camera` where AR isn't available) |
| `-photo <path>` | reads an image file as if it had been picked (with `-source photo`) |
| `-api <url>` | backend address, remembered for later launches (e.g. the Mac's address on a phone) |

### 4. Run the app on an iPhone

The live camera overlay only works on a real device. One-time setup first, then the
everyday run.

**One-time setup**

1. **Pair the phone with the Mac.** Connect it by cable, unlock it, and tap **Trust** on
   *"Trust This Computer?"*. If no prompt appears, start pairing from the Mac:
   `xcrun devicectl list devices` (note the phone's identifier), then
   `xcrun devicectl manage pair --device <identifier>`.
2. **Turn on Developer Mode** on the phone: Settings → Privacy & Security → scroll to the
   very bottom → **Developer Mode** → on → Restart → **Turn On**. The switch only appears
   after the phone has been paired with a Mac running Xcode; if it is still missing,
   open Xcode → Window → Devices and Simulators with the phone connected.
3. **Add your Apple ID to Xcode** (a free one works): Xcode → Settings → Accounts → **+**
   → Apple ID; then select it → **Manage Certificates… → + → Apple Development**.
4. **Set your team** in `ios/project.yml` (`DEVELOPMENT_TEAM`, currently the personal
   team `9P2NQ693B3`) and run `xcodegen generate`. Find your team id under Xcode →
   Settings → Accounts, or in Xcode: Etymon target → Signing & Capabilities → Team. If
   the bundle id is taken, change `PRODUCT_BUNDLE_IDENTIFIER` there too.
5. **Install once and trust the developer**: build and install (below). The first launch
   is refused until you allow it on the phone: Settings → General → **VPN & Device
   Management** → *Apple Development: your Apple ID* → **Trust**.
6. On first launch allow **camera** and **local network** access (without local network
   the app cannot reach the Mac).

**Every time**

1. Start the backend for the network (step 2): `--host 0.0.0.0`.
2. Phone and Mac on the **same Wi-Fi**. Find the Mac's address with
   `ipconfig getifaddr en0` (e.g. `192.168.178.133`).
3. Run the app:
   - **From Xcode**: choose the iPhone as the run destination, **⌘R**. Then in the app's
     **Settings** (gear) set the server to `http://<Mac address>:8000`.
   - **From the terminal** (passes the server address at launch; the app remembers it):

     ```sh
     cd ios
     xcodegen generate
     xcrun devicectl list devices            # the phone's identifier
     xcodebuild -project Etymon.xcodeproj -scheme Etymon -destination 'id=<identifier>' \
       -configuration Release -derivedDataPath build-device -allowProvisioningUpdates build
     xcrun devicectl device install app --device <identifier> \
       build-device/Build/Products/Release-iphoneos/Etymon.app
     xcrun devicectl device process launch --device <identifier> --terminate-existing \
       com.ranierovirgilio.etymon -api http://<Mac address>:8000 -source ar
     ```
   Release is optimized: large networks (a hundred words and more) move smoothly in
   Explore, which an unoptimized Debug build can't manage.
4. Point the camera at text: outlines appear on the words, shared roots float above them,
   same-meaning words are joined by dashed arcs, and the backend terminal prints each
   scene. **Hold** keeps the collected words while still tracking them.

If several Xcode versions are installed (e.g. a newer one not yet moved to
Applications), point the terminal commands at the right one without changing the system
default: `export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`.

### 5. Run the tests

With the backend running, from the repository root:

```sh
(cd backend && .venv/bin/pytest -q)                     # API
(cd ios && xcodebuild -project Etymon.xcodeproj -scheme Etymon \
  -destination 'platform=iOS Simulator,name=iPhone 17' test)  # app unit + UI tests
```

The UI tests drive the app in the simulator like a user (photo → overlay → detail sheets
→ graph; typed words and layers; Explore in 3D; saving a scene and opening it, its
lineages and Explore all with the server gone; the home menu, into a mode and back).
They start the app on
`http://localhost:8000` and with an empty, in-memory store of saved scenes. To keep their screenshots, add `TEST_RUNNER_ETYMON_SHOTS=/some/folder` in front
of the `xcodebuild` command.

### Stopping and troubleshooting

- **Stop the backend**: Ctrl+C in its terminal, or `pkill -f "uvicorn app:app"` — see
  [Stop it](#2-run-the-backend).
- **"Address already in use"** when starting the backend: one is already running on
  port 8000 — use it, or stop it with `kill $(lsof -ti tcp:8000)`.
- **Error banner in the app / nothing connects**: the backend isn't running, or the server
  address in the app's Settings is wrong (simulator: `http://localhost:8000`).
- **`database not found`** from `/health`: build the database (step 1), or point the
  backend at it with `ETYMON_DB=/path/to/etymon.sqlite`.
- **`xcodebuild` requires Xcode** / no iOS SDK: run the `xcode-select` command above.
- **Unable to find destination "iPhone 17"**: use a simulator you have, from
  `xcrun simctl list devices available`.
- **"The developer disk image could not be mounted"** when building for the phone: the
  phone's iOS is newer than Xcode supports — install a newer Xcode (and use it via
  `xcode-select` or `DEVELOPER_DIR`).
- **Phone shows *unpaired*** in `xcrun devicectl list devices`, or Developer Mode is
  missing in Settings: pair it (iPhone setup, step 1).
- **"invalid code signature … profile has not been explicitly trusted"** on launch:
  trust the developer on the phone (iPhone setup, step 5).
- **No signing certificate / no team**: add the Apple ID and an Apple Development
  certificate in Xcode (iPhone setup, step 3).
- **The phone can't reach the backend** (error banner, nothing in the monitor): same
  Wi-Fi for both; backend started with `--host 0.0.0.0`; local-network access allowed
  (phone Settings → Privacy & Security → Local Network → Etymon); server address in the
  app's Settings is the Mac's current IP (it can change after a restart or network
  switch). Test from the Mac: `curl http://<Mac address>:8000/health`.

## iOS app

SwiftUI, iOS 17+, in `ios/`. The Xcode project is generated from `ios/project.yml` by
XcodeGen and is not checked in. Setup and running: see [Getting started](#getting-started).

The same guide is in the app: tap **?** in the toolbar.

### Using the app

**Home** — the app opens on a menu of every mode (AR or Camera, Photo, Type, Talk) and
**My network**, over the icon's tree come alive: its branches grow, sway and carry light
out to their glowing dots (still with Reduce Motion). **?** and the gear are at the top.
In a mode, the house button goes back home; if the scene isn't saved, it asks first.

**Modes** (the switch at the top, or the home menu):

- **AR** (the default) — point the phone at text and the words are pinned where they are in the room;
  each shared root floats above the words it joins, linked to them, and same-meaning
  pairs are joined by green dashed arcs. Walk around: the network stays put, and words
  read on different walls and signs connect across the space. Tap a word or a root for
  its details. Tap a line to see only that branch: a shared root with every ancestor on
  the way up from each word (coloured by how each step was taken: gold inherited, orange
  borrowed) and its older ancestry above it, or a same-meaning pair; **Show all** or a tap
  on empty space brings the whole network back. **Hold/Collect** and **Explore** are at the bottom right.
- **Camera** — only on devices without world tracking, in place of AR: the network is
  drawn flat over the live video, anchored to the words, and follows them as you move.
- **Photo** — pick a picture with text; the network is drawn over it.
- **Type** — type or paste words and press **Connect**; the network is shown as a graph.

**Reading the overlay:**

| you see | it means |
|---|---|
| yellow outline on a word | the word is connected to another word in the scene |
| thin white outline | the word was read but isn't connected to anything (yet) |
| yellow bubble above words, solid yellow lines | **shared root**: the words descend from this ancestor (e.g. *notte* and *night* from Proto-Indo-European *\*nókʷts*); italic with `*` = reconstructed, never written down |
| `= night` inside a bubble | the words share the root **and** mean the same |
| green dashed arc with `= open` | **same meaning** in different languages, without a shared root (*Aperta* = *Open*) |

**Collecting words in the camera — Hold and Collect.** These are one button that
switches between two modes; the label is the action it will take:

- **Normal (button reads *Hold*)** — the app keeps collecting. About once a second it
  reads the frame carefully and **adds new words** to the scene, up to the **Maximum
  words** set in Settings (20 by default, 5–200). When more words are in view than that,
  the scene stays stable: words still in view keep their place, only words that have
  left the frame make room, and new words are taken largest on screen first, then in
  reading order — so the same view always gives the same words, then asks for the network again. Pan across a street and words from
  different signs accumulate and connect to each other.
- **Held (button reads *Collect*)** — the scene is **frozen**: no new words are added and
  the network stays as it is, but the collected words are still **tracked** — outlines,
  bubbles and arcs keep following them as you move, ~10 times a second. Words that leave
  the frame fade out and come back when you point at them again. Use it when you've found
  an interesting set of words and don't want new text crowding them out.
- Tap **Collect** to go back to normal and add new words again.

**Explore — the word network behind the picture, in 3D.** The **Explore** button
(next to Hold/Collect in the camera; in the status line for photo and type) stops the
video and opens the scene's network as a 3D space:

- The words that were seen sit at the bottom (blue); their ancestors rise above them,
  the older the higher (yellow; stronger yellow = shared roots); words brought in by
  Expand are grey. Yellow links are descent, orange borrowing, green same meaning.
- **Move around**: drag to turn, pinch to zoom, two fingers to move.
- **Move a word**: press and hold it, then drag; it stays where it is put and its links
  follow.
- **Jump**: tap a word — the camera flies to it and the panel shows its language, its
  meaning, what it **comes from**, what it **gave** and what has the **same meaning**.
  Tap any of those to jump on, from word to word.
- **Expand**: bring in the word's own parents and descendants from the dictionary,
  beyond the scene (Latin *pater* adds German *Pater*, English *Paternoster*, Spanish
  *padrastro*…), and keep exploring from there. **Lineage** shows its full ancestry.
- **Back** returns to the camera, and the video resumes.

The backend serves Expand with `GET /neighbors?id=<node>` (parents and up to 16
children, modern and common words first); the monitor prints an `explore` line for each.

**Your saved network — Save and My network.** Scenes can be kept on the phone and
explored later, without the server:

- **Save** (bookmark, in the status line once a network is shown) keeps the scene as it is
  at that moment: its words, the network the backend found for them, and the picture it
  was read from (the last carefully read video frame, or the photo) with where each word
  was in it. A sheet asks **what it was on**. It suggests names from the picture (on-device
  image classification: *sign*, *menu*, *book*…), and you can type your own and add a
  note. If you allow location, it also stores **where** you were (coordinates and a street and
  town); the date and time are always stored. **Remember where** turns location off.
- **My network** (books, top left) lists the saved scenes, newest first, with a search
  across words, objects, notes and places, and a **Map** of where each was found. Swipe to
  delete.
- **Open a scene** to see its picture with the network drawn over it exactly as it was (or the graph, for typed
  and heard words), switch Roots/Meanings, open the Graph or Explore it in 3D, tap words
  for their lineage, and rename it or edit its note.
- **Explore all** joins every saved scene (or those matching the search) into one 3D
  network. Scenes connect where their networks share a node, where words of different
  scenes mean the same thing, and through each word's lineage: *padre* saved on one sign
  and *paternal* in a book meet at Latin *pater*. Each scene word shows **seen on**, with
  the object, place and date of every scene it was found in.
- **Offline**: saved scenes are stored on the device (SwiftData) and need no server.
  The app also keeps every answer to a lookup (`/word` lineages, `/neighbors` for Expand)
  in Application Support, and uses it when the server can't be reached. The lineage of each word
  is fetched when a scene is saved, so Lineage and Explore all work offline straight
  away. Expanding a word that was never expanded before still needs the server.

**Other controls:**

- **Trash** (top left) — clear the scene and start fresh.
- **Books** (top left) — My network, the saved scenes (see above).
- **Graph** (bottom right, camera and photo) — the same network as a diagram.
- **Both · Roots · Meanings** — what the network shows: shared roots (etymological
  connections), same meanings (semantic connections), or both side by side. The switch
  sits above the graph; in camera and photo it is the layers menu at the bottom right,
  and the overlay follows the same choice. The choice is remembered.
- **Full paths** (graph) — show every step of each chain instead of just the shared
  ancestor.
- **Tap a bubble** — how the two words reach their shared ancestor, step by step, and the
  deeper line above it to the oldest known root.
- **Tap a word** — that word's own lineage. A word made of others goes back through
  each of them: *football* to *foot* and to *ball*, *Handschuh* to *Hand* and *Schuh*.
- **Gear** (top right) — Settings: **Maximum words** a scene can discover at once
  (5–200, default 20, in steps of 5 up to 50 and of 10 above; lowering it drops the
  oldest words now), My network (remember where scenes are saved, offline lookups kept
  and clearing them, delete all saved scenes), search depth, and the backend address
  (simulator: `http://localhost:8000`; phone: `http://<Mac address>:8000`).
- **?** — this guide.

The status line at the bottom counts the words, shared roots and same-meaning links, and
shows the scene's detected language.

Under the hood the camera reads the frame carefully about once a second (new words,
language) and quickly ~10 times a second in between to re-locate known words.

## Backend

FastAPI over the SQLite graph, in `backend/`: the app sends the words it recognised and
gets the network back. Setup and running: see [Getting started](#getting-started).

`POST /scene` — the words seen together (returns shared-ancestry `connections` and
same-meaning `semantic` links), optionally with the scene's likely language:

```json
{"lang": "it", "words": [{"text": "padre"}, {"text": "paternalistic", "lang": "en"}]}
```

returns each word's resolved terms, and for every pair that shares ancestry the nearest
meeting point (*pater*), both paths to it, and the `deeper` ancestry above it
(*\*patēr* → *\*ph₂tḗr* → root *\*peh₂-*), plus a `nodes` table for labels.
An ancestry is a tree, not one line: a compound has an ancestor for each part
(*Eisenbahn* → *Eisen* and *Bahn*). Each step carries `from`, the node it is an ancestor
of; the main line comes first (`connect.ancestry`, up to 40 steps).
Up to 500 words per scene (`MAX_WORDS`): about a second for 500, half a second for 200.
`GET /word?text=padri&lang=it` gives one word's ancestry the same way;
`GET /neighbors?id=<node>` a node's parents and children (Explore's Expand). The app keeps
the answers of these two lookups on the phone, for offline use. `ETYMON_DB` points at the database
(default `pipeline/data/etymon.sqlite`).

### Backend monitor

The terminal running the backend doubles as a live monitor of what the app is doing.
Start the backend in a terminal window you keep visible:

```sh
cd backend
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000 --no-access-log
```

Each request the app makes prints one readable block:

```
15:56:30  scene  it  7 words · 2 shared roots · 3 same meaning · 53 ms
          FARMACIA ↔ Pharmacy  → pharmacia (Medieval Latin)
          notte ↔ night        → *nókʷts (Proto-Indo-European)
          FARMACIA = Pharmacy  (pharmacy)
          Aperta = Open  (open)
          notte = night  (night)
          not connected: Padre
15:56:30  word   notte (it)  nox → *nok⁽ʷ⁾ts → *nókʷts
```

| line | meaning |
|---|---|
| `scene  it  7 words …` | a scene arrived: the scene's detected language (`--` if unknown), how many words, how many pairs share an ancestor (yellow) or a meaning (green), and how long the backend took |
| `A ↔ B  → ancestor (language)` | an etymological connection: the two words and their nearest shared ancestor |
| `A = B  (meaning)` | a semantic connection: different languages, same English meaning |
| `not connected: …` | words recognised but related to nothing else in the scene |
| `word   notte (it)  nox → …` | a word was tapped: its lineage up to the oldest known ancestor |
| `word   xyz  not found` | a tapped word has no entry |

What to look for:

- **Is the app reaching the backend?** With the camera on text, a new `scene` block should
  appear within a second or two whenever new words come into view. Nothing at all means
  the phone can't reach the Mac (see [troubleshooting](#stopping-and-troubleshooting)).
- **Is text recognition reading the right words?** The block lists exactly what the app
  sent; misread words show up as `not connected`.
- **Is the language right?** The scene's language decides how ambiguous words are read
  (*farmacia* as Italian, not Spanish).
- **Is it fast enough?** Scenes normally take tens of milliseconds; much more means the
  database is on slow storage or the scene is unusually large (up to the Maximum words setting, at most 200: a few hundred milliseconds).

Options:

- Leave out `--no-access-log` to also print uvicorn's raw line per request, with the
  client's IP address and HTTP status — useful to tell several devices apart:
  `INFO:  192.168.178.76:56180 - "POST /scene HTTP/1.1" 200 OK`
- `NO_COLOR=1` before the command prints plain text (no colours) in the terminal too.

### Backend logs

The backend's log is its terminal output: the monitor blocks above, plus uvicorn's
startup and shutdown lines and any errors (with Python tracebacks). Nothing is written to
disk unless you send it there. All of it goes to the terminal's error stream, which is
why the commands below use `2>&1`. When the output goes to a file, colours are turned off
automatically.

**Watch and save at the same time** (the backend runs in this window; Ctrl+C stops it):

```sh
cd backend
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000 --no-access-log 2>&1 | tee -a backend.log
```

**Run it in the background** and keep the log in a file, so the terminal is free:

```sh
cd backend
nohup .venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000 --no-access-log \
  >> backend.log 2>&1 &
```

It keeps running after the terminal is closed; stop it with
`pkill -f "uvicorn app:app"` (see [Stop it](#2-run-the-backend)).

**Read the log:**

| to | run (in `backend/`) |
|---|---|
| follow it live | `tail -f backend.log` — Ctrl+C closes only the view, not the server |
| see the last 50 lines | `tail -n 50 backend.log` |
| find errors | `grep -n -A20 Traceback backend.log` |
| find a word's scenes | `grep -n -A8 "padre" backend.log` |
| start a fresh log | `: > backend.log` (empties it; the server keeps writing) |

`-a` / `>>` append, so each session adds to the same file; the timestamps at the start of
each line tell sessions apart. Log files are ignored by git (`*.log`).

**The app's side.** The iOS app doesn't write a log of its own; what it sends is exactly
what the backend logs. A request that fails shows as the red error banner in the app, and
the system messages (crashes, network refusals) are in Xcode's debug console (⇧⌘C) when
running from Xcode. From the terminal, for the simulator:
`xcrun simctl spawn booted log stream --predicate 'process == "Etymon"'`.

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
| `build_graph.py` | builds `data/etymon.sqlite` from the slimmed dumps, then runs `refine.py` |
| `refine.py` | joins what citation habits split: cited spellings of reconstructions onto their entry (*\*septmós* → *\*septm̥mós*), and lists the affixes the search may pass through (`open_affix`: combining forms like *bio-* → *βίος*, not grammatical ones like *-zione*); rerunnable on a built database |
| `test_refine.py` | checks of these passes on small hand-made graphs (`../backend/.venv/bin/python -m pytest test_refine.py`) |
| `build_meanings.py` | adds same-meaning links (`meaning` table) |
| `geo.py` | places each language on the map (`language_geo` table): Glottolog points, hand-placed proto-language homelands; rerun after `build_graph.py` |
| `query.py it padri` | explore one word |
| `connect.py it padre en paternalistic` | what two words have in common |
| `export_mobile.py` | a pruned, app-sized copy of the graph, for a possible full dictionary on the phone (today offline use relies on saved scenes and cached lookups) |

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
