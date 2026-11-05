"""Etymon API: the words seen in a scene in, the network of shared ancestry out.

    POST /scene   {"words": [{"text": "padre", "lang": "it"}, {"text": "paternalistic"}],
                   "max_cost": 16}   (search depth, optional)
                  -> etymological connections (shared ancestors) and semantic links
                     (same meaning across languages: aperta = open)
    GET  /word?text=padri&lang=it
    GET  /health

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
from pydantic import BaseModel, Field

PIPELINE = Path(__file__).resolve().parent.parent / "pipeline"
sys.path.insert(0, str(PIPELINE))
from connect import MAX_COST, climb, is_affix, lineage, meetings  # noqa: E402
from query import MODERN, resolve  # noqa: E402

DB_PATH = Path(os.environ.get("ETYMON_DB", PIPELINE / "data" / "etymon.sqlite"))
MAX_WORDS = 30
MAX_SEARCH_DEPTH = 40
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


def log_scene(body, words, connections, semantic, nodes, ms):
    roots, same = len(connections), len(semantic)
    lines = [f"{_c('1;36', 'scene')}  {body.lang or '--'}  {len(words)} words · "
             f"{_c('33', f'{roots} shared roots')} · {_c('32', f'{same} same meaning')} · "
             f"depth {body.max_cost:g} · {ms:.0f} ms"]
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
    max_cost: float = Field(MAX_COST, ge=1, le=MAX_SEARCH_DEPTH,
                            description="search depth: how far up each word's ancestry to "
                                        "climb, in edge costs (most links cost 1, a root 6)")


class Step(BaseModel):
    node: int
    kind: str | None  # edge kind used to reach this node; None for the starting word


class Connection(BaseModel):
    a: int  # index into words
    b: int
    meet: int  # node id of the nearest shared ancestor
    distance: float  # cost of both paths together
    depth: float  # cost of the longer of the two paths: the search depth this connection needs
    path_a: list[Step]  # word a ... meet
    path_b: list[Step]  # word b ... meet
    deeper: list[Step]  # meet ... oldest known ancestor / reconstructed root


class SemanticLink(BaseModel):
    a: int  # index into words
    b: int
    meaning: str  # the shared English meaning: aperta = open


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
    max_cost: float  # the search depth asked for
    reached: float  # how far up the deepest climb actually got (<= max_cost)
    depth: float  # depth of the deepest connection found (0 if none)


class SceneOut(BaseModel):
    search: Search
    words: list[WordOut]
    connections: list[Connection]  # shared etymological ancestry
    semantic: list[SemanticLink]  # same meaning, different languages
    nodes: dict[int, Node]


# ---------- helpers ----------

def normalize(text):
    return text.strip(PUNCT)


# A word stays in the scene's language unless another language uses it this much more
# (Zipf points; 1 = ten times as frequent): "night" on an Italian sign is English.
HINT_MARGIN = 1.0


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
        if found[best][1] < found[hint][1] + HINT_MARGIN or not found[best][2]:
            best = hint
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


# ---------- endpoints ----------

@app.get("/health")
def health():
    return {"ok": DB_PATH.exists(), "db": DB_PATH.name}


@app.post("/scene", response_model=SceneOut)
def scene(body: SceneIn, db: sqlite3.Connection = Depends(get_db)):
    started = time.perf_counter()
    words, trees, seen = [], [], set()
    for w in body.words:
        text = normalize(w.text)
        key = (text.lower(), w.lang)
        if not text or key in seen:
            continue
        seen.add(key)
        lang, ids = best_language(db, text, w.lang, hint=body.lang)
        words.append(WordOut(text=text, lang=lang, terms=ids, meanings=meanings_for(db, ids)))
        trees.append(climb(db, ids, body.max_cost) if ids else {})

    connections, used = [], set()
    for (i, ta), (j, tb) in combinations(enumerate(trees), 2):
        if not ta or not tb or set(words[i].terms) & set(words[j].terms):
            continue
        for distance, meet, pa, pb in meetings(ta, tb, body.connections_per_pair):
            deeper = lineage(db, meet)
            connections.append(Connection(a=i, b=j, meet=meet, distance=distance,
                                          depth=max(ta[meet][0], tb[meet][0]),
                                          path_a=steps(pa), path_b=steps(pb),
                                          deeper=steps(deeper)))
            used.update(n for n, _ in pa + pb + deeper)
    connections.sort(key=lambda c: c.distance)
    used.update(t for w in words for t in w.terms)
    semantic = semantic_links(words)
    nodes = nodes_for(db, used)
    log_scene(body, words, connections, semantic, nodes, (time.perf_counter() - started) * 1000)
    search = Search(max_cost=body.max_cost,
                    reached=max((c for t in trees for c, _, _ in t.values()), default=0.0),
                    depth=max((c.depth for c in connections), default=0.0))
    return SceneOut(search=search, words=words, connections=connections, semantic=semantic,
                    nodes=nodes)


@app.get("/word")
def word(text: str, lang: str | None = Query(None), db: sqlite3.Connection = Depends(get_db)):
    """A single word's lineage, for tapping a word in the scene."""
    lang, ids = best_language(db, normalize(text), lang)
    if not ids:
        log.info(f"{_c('1;35', 'word ')}  {text}  {_c('2', 'not found')}")
        raise HTTPException(404, "word not found")
    out, used = [], set(ids)
    for tid in ids:
        line = lineage(db, tid)
        used.update(n for n, _ in line)
        out.append({"term": tid, "lineage": steps(line)})
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
        (id, *DESCENT)) if not is_affix(w)][:10]
    modern = ",".join(f"'{m}'" for m in MODERN)
    kids = [Step(node=s_, kind=k) for s_, k, w in db.execute(
        f"SELECT e.src, e.kind, t.word FROM edge e JOIN term t ON t.id=e.src "
        f"WHERE e.dst=? AND e.kind IN ({marks}) "
        f"ORDER BY (t.lang IN ({modern})) DESC, coalesce(t.zipf, 0) DESC, t.has_entry DESC, e.inferred "
        f"LIMIT ?", (id, *DESCENT, children * 3)) if not is_affix(w)][:children]
    used = {id} | {p.node for p in parents} | {c.node for c in kids}
    nodes = nodes_for(db, used)
    total = db.execute(f"SELECT count(*) FROM edge WHERE dst=? AND kind IN ({marks})",
                       (id, *DESCENT)).fetchone()[0]
    n = nodes.get(id)
    log.info(f"{_c('1;34', 'explore')}  {n.word if n else id} ({n.language if n else '?'})  "
             f"{len(parents)} parents · {len(kids)} of {total} children")
    return {"node": id, "parents": parents, "children": kids, "total_children": total,
            "meanings": meanings_for(db, [id]), "nodes": nodes}
