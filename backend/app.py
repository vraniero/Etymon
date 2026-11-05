"""Etymon API: the words seen in a scene in, the network of shared ancestry out.

    POST /scene   {"words": [{"text": "padre", "lang": "it"}, {"text": "paternalistic"}]}
                  -> etymological connections (shared ancestors) and semantic links
                     (same meaning across languages: aperta = open)
    GET  /word?text=padri&lang=it
    GET  /health

Run: .venv/bin/uvicorn app:app --reload        (from backend/)
DB:  ETYMON_DB=/path/to/etymon.sqlite          (default: ../pipeline/data/etymon.sqlite)
"""
import os
import sqlite3
import sys
from itertools import combinations
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

PIPELINE = Path(__file__).resolve().parent.parent / "pipeline"
sys.path.insert(0, str(PIPELINE))
from connect import climb, lineage, meetings  # noqa: E402
from query import MODERN, resolve  # noqa: E402

DB_PATH = Path(os.environ.get("ETYMON_DB", PIPELINE / "data" / "etymon.sqlite"))
MAX_WORDS = 30
PUNCT = " \t\n.,;:!?¡¿\"'“”‘’«»()[]{}"

app = FastAPI(title="Etymon", version="0.1")


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


class Step(BaseModel):
    node: int
    kind: str | None  # edge kind used to reach this node; None for the starting word


class Connection(BaseModel):
    a: int  # index into words
    b: int
    meet: int  # node id of the nearest shared ancestor
    distance: float
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


class WordOut(BaseModel):
    text: str
    lang: str | None
    terms: list[int]  # node ids the text resolves to (lemma, homographs)
    meanings: list[str] = []  # English meaning keys (empty if unknown)


class SceneOut(BaseModel):
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
    return db.execute("SELECT 1 FROM sqlite_master WHERE name='meaning'").fetchone() is not None


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
    rows = db.execute(
        f"SELECT t.id, t.lang, coalesce(l.name, t.lang), t.word, t.gloss FROM term t "
        f"LEFT JOIN language l ON l.code=t.lang WHERE t.id IN ({','.join('?' * len(ids))})",
        list(ids))
    return {i: Node(id=i, lang=lang, language=name, word=word, gloss=gloss,
                    reconstructed=word.startswith("*"))
            for i, lang, name, word, gloss in rows}


def steps(p):
    return [Step(node=n, kind=k) for n, k in p]


# ---------- endpoints ----------

@app.get("/health")
def health():
    return {"ok": DB_PATH.exists(), "db": DB_PATH.name}


@app.post("/scene", response_model=SceneOut)
def scene(body: SceneIn, db: sqlite3.Connection = Depends(get_db)):
    words, trees, seen = [], [], set()
    for w in body.words:
        text = normalize(w.text)
        key = (text.lower(), w.lang)
        if not text or key in seen:
            continue
        seen.add(key)
        lang, ids = best_language(db, text, w.lang, hint=body.lang)
        words.append(WordOut(text=text, lang=lang, terms=ids, meanings=meanings_for(db, ids)))
        trees.append(climb(db, ids) if ids else {})

    connections, used = [], set()
    for (i, ta), (j, tb) in combinations(enumerate(trees), 2):
        if not ta or not tb or set(words[i].terms) & set(words[j].terms):
            continue
        for distance, meet, pa, pb in meetings(ta, tb, body.connections_per_pair):
            deeper = lineage(db, meet)
            connections.append(Connection(a=i, b=j, meet=meet, distance=distance,
                                          path_a=steps(pa), path_b=steps(pb),
                                          deeper=steps(deeper)))
            used.update(n for n, _ in pa + pb + deeper)
    connections.sort(key=lambda c: c.distance)
    used.update(t for w in words for t in w.terms)
    return SceneOut(words=words, connections=connections, semantic=semantic_links(words),
                    nodes=nodes_for(db, used))


@app.get("/word")
def word(text: str, lang: str | None = Query(None), db: sqlite3.Connection = Depends(get_db)):
    """A single word's lineage, for tapping a word in the scene."""
    lang, ids = best_language(db, normalize(text), lang)
    if not ids:
        raise HTTPException(404, "word not found")
    out, used = [], set(ids)
    for tid in ids:
        line = lineage(db, tid)
        used.update(n for n, _ in line)
        out.append({"term": tid, "lineage": steps(line)})
    return {"text": text, "lang": lang, "meanings": meanings_for(db, ids), "entries": out,
            "nodes": nodes_for(db, used)}
