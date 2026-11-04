"""Etymon API: the words seen in a scene in, the network of shared ancestry out.

    POST /scene   {"words": [{"text": "padre", "lang": "it"}, {"text": "paternalistic"}]}
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


class SceneOut(BaseModel):
    words: list[WordOut]
    connections: list[Connection]
    nodes: dict[int, Node]


# ---------- helpers ----------

def normalize(text):
    return text.strip(PUNCT)


def best_language(db, text, lang):
    """Resolve text to term ids; without a language, pick the modern language where the
    word is most frequent (and actually has etymology to show)."""
    if lang:
        return lang, resolve(db, lang, text)
    best = (None, [], -1.0)
    for code in MODERN:
        ids = resolve(db, code, text)
        if not ids:
            continue
        zipf = max((db.execute("SELECT coalesce(zipf, 0) FROM term WHERE id=?", (i,))
                    .fetchone()[0] for i in ids), default=0)
        has_edges = db.execute(f"SELECT 1 FROM edge WHERE src IN ({','.join('?' * len(ids))}) "
                               f"LIMIT 1", ids).fetchone() is not None
        score = zipf + (10 if has_edges else 0)
        if score > best[2]:
            best = (code, ids, score)
    return best[0], best[1]


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
        lang, ids = best_language(db, text, w.lang or body.lang)
        if not ids and not w.lang and body.lang:
            lang, ids = best_language(db, text, None)  # e.g. an English word on an Italian sign
        words.append(WordOut(text=text, lang=lang, terms=ids))
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
    return SceneOut(words=words, connections=connections, nodes=nodes_for(db, used))


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
    return {"text": text, "lang": lang, "entries": out, "nodes": nodes_for(db, used)}
