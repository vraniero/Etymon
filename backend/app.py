"""Etymon API: the words seen in a scene in, the network of shared ancestry out.

    POST /scene   {"words": [{"text": "padre", "lang": "it"}, {"text": "paternalistic"}],
                   "max_cost": 16}   (search depth, optional)
                  -> etymological connections (shared ancestors) and semantic links
                     (same meaning across languages: aperta = open)
    GET  /word?text=padri&lang=it
    GET  /health
    WS   /listen  live audio -> utterances by persona (see listen.py)

Run: .venv/bin/uvicorn app:app --reload        (from backend/)
DB:  ETYMON_DB=/path/to/etymon.sqlite          (default: ../pipeline/data/etymon.sqlite)
"""
import logging
import os
import sqlite3
import sys
import time
from itertools import combinations
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field

PIPELINE = Path(__file__).resolve().parent.parent / "pipeline"
sys.path.insert(0, str(PIPELINE))
from connect import MAX_COST, ancestry, climb, closed, lineage, meetings  # noqa: E402
from query import MODERN, resolve  # noqa: E402

DB_PATH = Path(os.environ.get("ETYMON_DB", PIPELINE / "data" / "etymon.sqlite"))
MAX_WORDS = 500  # per scene; the app's word limit (up to 200) stays well under it
MAX_SEARCH_DEPTH = 40
# Automatic depth: everything at the default first; words still unconnected are searched
# again, deeper, until each has a link or the deepest is reached. Deeper searches find
# more distant (and more doubtful) roots, so words already connected don't get them.
AUTO_DEPTHS = (MAX_COST, 24, 32, MAX_SEARCH_DEPTH)
PUNCT = " \t\n.,;:!?¡¿\"'“”‘’«»()[]{}"

app = FastAPI(title="Etymon", version="0.1")

# Monitor: one readable block per scene / word lookup on the server's console.
log = logging.getLogger("etymon")
if not log.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(asctime)s  %(message)s", "%H:%M:%S"))
    log.addHandler(_handler)
    log.setLevel(logging.INFO)
    log.propagate = False
_COLOR = sys.stderr.isatty() and os.environ.get("NO_COLOR") is None


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def log_scene(body, words, connections, semantic, nodes, ms, searched):
    roots, same = len(connections), len(semantic)
    lines = [f"{_c('1;36', 'scene')}  {body.lang or '--'}  {len(words)} words · "
             f"{_c('33', f'{roots} shared roots')} · {_c('32', f'{same} same meaning')} · "
             f"depth {'auto ' if body.max_cost is None else ''}{searched:g} · {ms:.0f} ms"]
    width = max([len(f"{words[c.a].text} ↔ {words[c.b].text}") for c in connections] + [0])
    for c in connections:
        pair = f"{words[c.a].text} ↔ {words[c.b].text}"
        n = nodes.get(c.meet)
        meet = f"{n.word} ({n.language})" if n else str(c.meet)
        lines.append(f"          {pair:<{width}}  → {_c('33', meet)}")
    for l in semantic:
        lines.append(f"          {words[l.a].text} = {words[l.b].text}  {_c('32', '(' + l.meaning + ')')}")
    linked = {i for c in connections for i in (c.a, c.b)} | {i for l in semantic for i in (l.a, l.b)}
    loose = [w.text for i, w in enumerate(words) if i not in linked]
    if loose:
        lines.append(_c("2", "          not connected: " + ", ".join(loose)))
    log.info("\n".join(lines))


def get_db():
    if not DB_PATH.exists():
        raise HTTPException(503, f"database not found: {DB_PATH}")
    db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, check_same_thread=False)
    try:
        yield db
    finally:
        db.close()


# ---------- models ----------

class WordIn(BaseModel):
    text: str
    lang: str | None = Field(None, description="ISO code (it, en...); detected if omitted")


class SceneIn(BaseModel):
    words: list[WordIn] = Field(..., max_length=MAX_WORDS)
    lang: str | None = Field(None, description="likely language of the whole scene, tried "
                                               "first for words without their own lang")
    connections_per_pair: int = Field(1, ge=1, le=3)
    max_cost: float | None = Field(None, ge=1, le=MAX_SEARCH_DEPTH,
                                   description="search depth: how far up each word's ancestry "
                                               "to climb, in edge costs (most links cost 1, a "
                                               "root 6); none: automatic, deeper only for "
                                               "words left unconnected")


class Step(BaseModel):
    model_config = ConfigDict(populate_by_name=True)
    node: int
    kind: str | None  # edge kind used to reach this node; None for the starting word
    # In an ancestry (deeper, a word's lineage), the node this one is an ancestor of: a
    # compound has several (football: foot and ball). Absent in a path, which is one line.
    from_: int | None = Field(None, alias="from")


class Connection(BaseModel):
    a: int  # index into words
    b: int
    meet: int  # node id of the nearest shared ancestor
    distance: float  # cost of both paths together
    depth: float  # cost of the longer of the two paths: the search depth this connection needs
    path_a: list[Step]  # word a ... meet
    path_b: list[Step]  # word b ... meet
    deeper: list[Step]  # everything above meet, each step with its "from": the main line
                        # to the oldest known ancestor first, then other branches


class SemanticLink(BaseModel):
    a: int  # index into words
    b: int
    meaning: str  # the shared English meaning: aperta = open


class SameWord(BaseModel):
    a: int  # index into words
    b: int
    lemma: int  # node id of the entry both are forms of: invitato and invitare -> invitare


class Node(BaseModel):
    id: int
    lang: str
    language: str
    word: str
    gloss: str | None
    reconstructed: bool
    lat: float | None = None  # where the language was spoken (pipeline/geo.py); None if unknown
    lon: float | None = None


class WordOut(BaseModel):
    text: str
    lang: str | None
    terms: list[int]  # node ids the text resolves to (lemma, homographs)
    meanings: list[str] = []  # English meaning keys (empty if unknown)


class Search(BaseModel):
    max_cost: float  # the search depth asked for; automatic: the deepest it went
    auto: bool = False  # automatic depth
    reached: float  # how far up the deepest climb actually got (<= max_cost)
    depth: float  # depth of the deepest connection found (0 if none)


class SceneOut(BaseModel):
    search: Search
    words: list[WordOut]
    connections: list[Connection]  # shared etymological ancestry
    semantic: list[SemanticLink]  # same meaning, different languages
    same_word: list[SameWord] = []  # forms of one word (padre, padri): not connected
                                    # through an ancestor, since they share every one
    nodes: dict[int, Node]


# ---------- helpers ----------

def normalize(text):
    return text.strip(PUNCT)


# A word stays in the scene's language unless English uses it this much more (Zipf
# points; 1 = ten times as frequent): "night" on an Italian sign is English. Only English,
# the lingua franca of signs: among twenty languages a short word is nearly always common
# somewhere else too (Hungarian tej, milk, is Polish for "this").
HINT_MARGIN = 1.0
HINT_YIELDS_TO = "en"


def candidates(db, text):
    """{lang: (ids, zipf, has_edges)} for every modern language the text resolves in."""
    out = {}
    for code in MODERN:
        ids = resolve(db, code, text)
        if not ids:
            continue
        zipf = max(db.execute("SELECT coalesce(zipf, 0) FROM term WHERE id=?", (i,)).fetchone()[0]
                   for i in ids)
        has_edges = db.execute(f"SELECT 1 FROM edge WHERE src IN ({','.join('?' * len(ids))}) "
                               f"LIMIT 1", ids).fetchone() is not None
        out[code] = (ids, zipf, has_edges)
    return out


def best_language(db, text, lang, hint=None):
    """Resolve text to (lang, term ids). An explicit lang is taken as given. Otherwise the
    scene's hinted language wins unless the word is much more common elsewhere; with no
    hint, the language where the word is most frequent and has etymology to show."""
    if lang:
        return lang, resolve(db, lang, text)
    found = candidates(db, text)
    if not found:
        return None, []
    best = max(found, key=lambda c: (found[c][2], found[c][1]))
    if hint in found:
        en = found.get(HINT_YIELDS_TO)
        best = HINT_YIELDS_TO if (hint != HINT_YIELDS_TO and en and en[2]
                                  and en[1] >= found[hint][1] + HINT_MARGIN) else hint
    return best, found[best][0]


def meanings_for(db, ids):
    if not ids or not has_meanings(db):
        return []
    rows = db.execute(f"SELECT DISTINCT key FROM meaning WHERE term IN "
                      f"({','.join('?' * len(ids))}) ORDER BY rowid", ids)
    return [k for (k,) in rows]


def has_meanings(db):
    return has_table(db, "meaning")


def has_table(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE name=?", (name,)).fetchone() is not None


def semantic_links(words):
    """Pairs of scene words in different languages that share an English meaning."""
    links = []
    for (i, a), (j, b) in combinations(enumerate(words), 2):
        if not a.meanings or not b.meanings or a.lang == b.lang:
            continue
        shared = [k for k in a.meanings if k in b.meanings]
        if shared:
            links.append(SemanticLink(a=i, b=j, meaning=shared[0]))
    return links


def nodes_for(db, ids):
    if not ids:
        return {}
    geo = has_table(db, "language_geo")
    rows = db.execute(
        f"SELECT t.id, t.lang, coalesce(l.name, t.lang), t.word, t.gloss, "
        f"{'g.lat, g.lon' if geo else 'NULL, NULL'} FROM term t "
        f"LEFT JOIN language l ON l.code=t.lang "
        f"{'LEFT JOIN language_geo g ON g.code=t.lang ' if geo else ''}"
        f"WHERE t.id IN ({','.join('?' * len(ids))})",
        list(ids))
    return {i: Node(id=i, lang=lang, language=name, word=word, gloss=gloss,
                    reconstructed=word.startswith("*"), lat=lat, lon=lon)
            for i, lang, name, word, gloss, lat, lon in rows}


def steps(p):
    return [Step(node=n, kind=k) for n, k in p]


def tree(a):
    """An ancestry's (node, kind, child) triples as steps."""
    return [Step(node=n, kind=k, from_=c) for n, k, c in a]


# ---------- endpoints ----------

@app.get("/health")
def health():
    return {"ok": DB_PATH.exists(), "db": DB_PATH.name}


@app.post("/scene", response_model=SceneOut)
def scene(body: SceneIn, db: sqlite3.Connection = Depends(get_db)):
    started = time.perf_counter()
    words, seen = [], set()
    for w in body.words:
        text = normalize(w.text)
        key = (text.lower(), w.lang)
        if not text or key in seen:
            continue
        seen.add(key)
        lang, ids = best_language(db, text, w.lang, hint=body.lang)
        words.append(WordOut(text=text, lang=lang, terms=ids, meanings=meanings_for(db, ids)))

    climbed = {}  # (word, depth) -> tree

    def tree_at(i, depth):
        if (i, depth) not in climbed:
            climbed[i, depth] = climb(db, words[i].terms, depth) if words[i].terms else {}
        return climbed[i, depth]

    connections, same_word, used, above = [], [], set(), {}
    linked = set()  # words with a connection or a same-word link

    def connect(i, j, depth):
        ta, tb = tree_at(i, depth), tree_at(j, depth)
        if not ta or not tb:
            return
        for distance, meet, pa, pb in meetings(ta, tb, body.connections_per_pair):
            if meet not in above:
                above[meet] = ancestry(db, meet)
            deeper = above[meet]
            connections.append(Connection(a=i, b=j, meet=meet, distance=distance,
                                          depth=max(ta[meet][0], tb[meet][0]),
                                          path_a=steps(pa), path_b=steps(pb),
                                          deeper=tree(deeper)))
            used.update(n for n, _ in pa + pb)
            used.update(n for n, _, _ in deeper)
            linked.update((i, j))

    depths = (body.max_cost,) if body.max_cost is not None else AUTO_DEPTHS
    pairs = []
    for i, j in combinations(range(len(words)), 2):
        shared = [t for t in words[i].terms if t in words[j].terms]
        if shared:
            same_word.append(SameWord(a=i, b=j, lemma=shared[0]))
            linked.update((i, j))
        else:
            pairs.append((i, j))
    searched = depths[0]
    for i, j in pairs:
        connect(i, j, searched)
    for depth in depths[1:]:
        loose = {i for i, w in enumerate(words) if w.terms and i not in linked}
        todo = [(i, j) for i, j in pairs if i in loose or j in loose]
        # deeper only helps where a tree grows: most ancestries run out well before
        involved = {k for p in todo for k in p}
        if not any(len(tree_at(k, depth)) > len(tree_at(k, searched)) for k in involved):
            break
        for i, j in todo:
            connect(i, j, depth)
        searched = depth
    connections.sort(key=lambda c: c.distance)
    used.update(t for w in words for t in w.terms)
    semantic = semantic_links(words)
    nodes = nodes_for(db, used)
    log_scene(body, words, connections, semantic, nodes, (time.perf_counter() - started) * 1000,
              searched)
    search = Search(max_cost=searched, auto=body.max_cost is None,
                    reached=max((c for t in climbed.values() for c, _, _ in t.values()),
                                default=0.0),
                    depth=max((c.depth for c in connections), default=0.0))
    return SceneOut(search=search, words=words, connections=connections, semantic=semantic,
                    same_word=same_word, nodes=nodes)


@app.get("/word")
def word(text: str, lang: str | None = Query(None), db: sqlite3.Connection = Depends(get_db)):
    """A single word's ancestry, for tapping a word in the scene: every ancestor, each
    step with the node it comes from (a compound goes back through each of its parts)."""
    lang, ids = best_language(db, normalize(text), lang)
    if not ids:
        log.info(f"{_c('1;35', 'word ')}  {text}  {_c('2', 'not found')}")
        raise HTTPException(404, "word not found")
    out, used = [], set(ids)
    for tid in ids:
        line = ancestry(db, tid)
        used.update(n for n, _, _ in line)
        out.append({"term": tid, "lineage": tree(line)})
    nodes = nodes_for(db, used)
    chain = " → ".join(nodes[n].word for n, _ in lineage(db, ids[0]) if n in nodes)
    log.info(f"{_c('1;35', 'word ')}  {text} ({lang})  {_c('2', chain)}")
    return {"text": text, "lang": lang, "meanings": meanings_for(db, ids), "entries": out,
            "nodes": nodes}


# ---------- explore ----------

DESCENT = ("inherited", "borrowed", "learned", "calque", "semantic_loan", "derived",
           "component", "root")


@app.get("/neighbors")
def neighbors(id: int, children: int = Query(16, ge=0, le=60),
              db: sqlite3.Connection = Depends(get_db)):
    """A node's immediate network, for exploring: where it comes from (parents) and what
    came from it (children; modern, common words first). Expanding pater gives padre,
    père, paternal, Pater... and from any of those one can keep going."""
    if not db.execute("SELECT 1 FROM term WHERE id=?", (id,)).fetchone():
        raise HTTPException(404, "node not found")
    marks = ",".join("?" * len(DESCENT))
    parents = [Step(node=d, kind=k) for d, k, w in db.execute(
        f"SELECT e.dst, e.kind, t.word FROM edge e JOIN term t ON t.id=e.dst "
        f"WHERE e.src=? AND e.kind IN ({marks}) ORDER BY e.inferred, "
        f"instr('inherited borrowed learned calque semantic_loan derived component root', e.kind)",
        (id, *DESCENT)) if not closed(db, d, w)][:10]
    modern = ",".join(f"'{m}'" for m in MODERN)
    kids = [Step(node=s_, kind=k) for s_, k, w in db.execute(
        f"SELECT e.src, e.kind, t.word FROM edge e JOIN term t ON t.id=e.src "
        f"WHERE e.dst=? AND e.kind IN ({marks}) "
        f"ORDER BY (t.lang IN ({modern})) DESC, coalesce(t.zipf, 0) DESC, t.has_entry DESC, e.inferred "
        f"LIMIT ?", (id, *DESCENT, children * 3)) if not closed(db, s_, w)][:children]
    used = {id} | {p.node for p in parents} | {c.node for c in kids}
    nodes = nodes_for(db, used)
    total = db.execute(f"SELECT count(*) FROM edge WHERE dst=? AND kind IN ({marks})",
                       (id, *DESCENT)).fetchone()[0]
    n = nodes.get(id)
    log.info(f"{_c('1;34', 'explore')}  {n.word if n else id} ({n.language if n else '?'})  "
             f"{len(parents)} parents · {len(kids)} of {total} children")
    return {"node": id, "parents": parents, "children": kids, "total_children": total,
            "meanings": meanings_for(db, [id]), "nodes": nodes}


# Conversation listening (WS /listen): audio in, who said which words out. Models load on
# the first connection, so the API starts as fast as before.
from listen import router as listen_router  # noqa: E402

app.include_router(listen_router)

# Root Chain, the word game (POST /chain/reply): the app's move.
from chain import router as chain_router  # noqa: E402

app.include_router(chain_router)

# The other word games: Impostor, Cousin Hunt, Scavenger, Birthplace.
from games import router as games_router  # noqa: E402

app.include_router(games_router)
