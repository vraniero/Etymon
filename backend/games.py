"""The word games besides Root Chain (chain.py). Each makes its puzzle from the graph:

    GET  /games/impostor?lang=it   four words: three share an ancestor, one only looks
                                   like them (or means the same)
    GET  /games/root?lang=it       an ancestor with many living descendants, for Cousin
                                   Hunt (name them) and Scavenger (find one around you)
    POST /games/check              {"root": 123, "words": [{"text": "padre"}]} -> which
                                   of the words descend from the root, and how
    GET  /games/birthplace?lang=en a word and where it was born: its oldest attested
                                   ancestor, placed on the map, and the way it came

`lang` is the game's language; without it, one of the five big ones at random.
"""
import math
import random
import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import app as api
from chain import common_words, descend, plain
from connect import MAX_COST, climb, lineage, meetings, path
from query import MODERN

router = APIRouter(prefix="/games")

DEFAULT_LANGUAGES = ("en", "it", "es", "fr", "de")
TRIES = 40  # puzzles attempted before giving up
CHECK_DEPTH = 24  # how far up a guessed word is climbed to find the root


def game_language(lang, rng):
    if lang is None:
        return rng.choice(DEFAULT_LANGUAGES)
    if lang not in MODERN:
        raise HTTPException(404, "unknown language")
    return lang


class Word(BaseModel):
    text: str
    lang: str
    language: str


def as_word(db, tid):
    n = api.nodes_for(db, [tid])[tid]
    return Word(text=n.word, lang=n.lang, language=n.language)


def line(db, tree, start, to):
    """Words from `start` up to `to` along a climbed tree, as node ids."""
    return [n for n, _ in path(tree, to)] if to in tree else [start]


# ---------- Impostor ----------

class ImpostorOut(BaseModel):
    words: list[Word]  # four, shuffled
    impostor: int  # index of the odd one
    root: int  # what the other three share
    why: str  # "looks" or "means": what makes the impostor a good disguise
    paths: list[list[int]]  # for each word, its way up to the root (the impostor's own line)
    nodes: dict[int, api.Node]


@router.get("/impostor", response_model=ImpostorOut)
def impostor(lang: str | None = None, seed: int | None = None,
             db: sqlite3.Connection = Depends(api.get_db)):
    rng = random.Random(seed)
    lang = game_language(lang, rng)
    words = list(common_words(db, lang))
    rng.shuffle(words)
    for tid, word in words[:TRIES]:
        if not plain(word):
            continue
        up = climb(db, [tid], 12)
        # an ancestor with at least two more living descendants in the language
        for cost, anc in sorted((c, n) for n, (c, _, _) in up.items() if n != tid):
            if cost < 1 or cost > 9:  # past that, a far root everything shares
                continue
            if len(db.execute("SELECT word FROM term WHERE id=?", (anc,)).fetchone()[0]
                   .strip("*-")) < 3:
                continue  # de, ad: a function word, not a family
            seen = {tid}
            below = descend(db, anc, seen, lambda w, l, z: l == lang and z >= 2.5
                            and w.lower() != word.lower())
            cousins = distinct(db, lang, [tid] + list(below), 3)
            if len(cousins) < 3:
                continue
            trees = {c: climb(db, [c], MAX_COST) for c in cousins}
            fake, why = disguise(db, lang, cousins, trees, rng)
            if fake is None:
                break  # this word has no impostor; try another
            four = cousins + [fake]
            rng.shuffle(four)
            trees[fake] = {fake: (0.0, None, None)}
            paths = [line(db, trees[c], c, anc) if c != fake
                     else [fake] + [n for n, _ in lineage(db, fake)][:4] for c in four]
            nodes = api.nodes_for(db, {n for p in paths for n in p} | {anc})
            api.log.info(f"{api._c('1;33', 'impostor')}  "
                         f"{', '.join(nodes[c].word for c in cousins)} ({nodes[anc].word}) "
                         f"vs {nodes[fake].word} [{why}]")
            return ImpostorOut(words=[as_word(db, c) for c in four], impostor=four.index(fake),
                               root=anc, why=why, paths=paths, nodes=nodes)
    raise HTTPException(404, "no puzzle found")


def distinct(db, lang, ids, n):
    """Up to n of the ids that are different words, not forms of one another, nor
    looking alike (eager, eagerly): the family should take some seeing."""
    out, terms, starts = [], set(), set()
    for t in ids:
        word = db.execute("SELECT word FROM term WHERE id=?", (t,)).fetchone()[0]
        own = set(api.resolve(db, lang, word)) | {t}
        if own & terms or word[:4].lower() in starts:
            continue
        terms |= own
        starts.add(word[:4].lower())
        out.append(t)
        if len(out) == n:
            break
    return out


def disguise(db, lang, cousins, trees, rng):
    """A word that looks like one of the cousins (same start) or means the same as one,
    but shares no ancestor with any of them."""
    def unrelated(t, word):
        # a word with its own etymology, not a form of another (documentazioni)
        if api.resolve(db, lang, word) != [t]:
            return False
        mine = climb(db, [t], MAX_COST)
        return len(mine) > 1 and all(not meetings(mine, tree, 1) for tree in trees.values())

    for c in rng.sample(cousins, len(cousins)):
        word = db.execute("SELECT word FROM term WHERE id=?", (c,)).fetchone()[0]
        for size in (4, 3):
            if len(word) <= size:
                continue
            rows = db.execute(
                "SELECT id, word FROM term WHERE lang=? AND word LIKE ? AND has_entry=1 "
                "AND coalesce(zipf, 0) >= 2.5 AND id != ? ORDER BY random() LIMIT 12",
                (lang, word[:size] + "%", c)).fetchall()
            for t, w in rows:
                if plain(w) and t not in cousins and unrelated(t, w):
                    return t, "looks"
        rows = db.execute(
            "SELECT m2.term FROM meaning m1 JOIN meaning m2 ON m2.key=m1.key "
            "JOIN term t ON t.id=m2.term WHERE m1.term=? AND t.lang=? AND m2.term != ? "
            "AND t.has_entry=1 LIMIT 12", (c, lang, c)).fetchall()
        for (t,) in rows:
            w = db.execute("SELECT word FROM term WHERE id=?", (t,)).fetchone()[0]
            if plain(w) and t not in cousins and unrelated(t, w):
                return t, "means"
    return None, ""


# ---------- Cousin Hunt, Scavenger ----------

class RootOut(BaseModel):
    root: api.Node
    lang: str  # the game's language
    total: int  # living descendants found in it
    examples: list[str]  # the commonest, shown after the round


MIN_DESCENDANTS = 8


@router.get("/root", response_model=RootOut)
def root(lang: str | None = None, seed: int | None = None,
         db: sqlite3.Connection = Depends(api.get_db)):
    """An ancestor with plenty of common living descendants in the language: Latin
    pater, Ancient Greek φάρμακον, Proto-Germanic *fōdô."""
    rng = random.Random(seed)
    lang = game_language(lang, rng)
    words = list(common_words(db, lang))
    rng.shuffle(words)
    for tid, word in words[:TRIES]:
        up = climb(db, [tid], 10)
        older = [n for n, (c, _, _) in up.items() if c >= 2]
        rng.shuffle(older)
        for anc in older[:4]:
            node = api.nodes_for(db, [anc]).get(anc)
            if not node or node.lang in MODERN or len(node.word.strip("*-")) < 3:
                continue
            below = descend(db, anc, set(), lambda w, l, z: l == lang and z >= 2.0,
                            generations=4)
            if len(below) >= MIN_DESCENDANTS:
                examples = sorted(below.values(), key=lambda v: -v[2])
                api.log.info(f"{api._c('1;33', 'root ')}  {node.word} ({node.language}) "
                             f"{len(below)} in {lang}")
                return RootOut(root=node, lang=lang, total=len(below),
                               examples=list(dict.fromkeys(w for w, _, _ in examples))[:12])
    raise HTTPException(404, "no root found")


class CheckIn(BaseModel):
    root: int
    words: list[api.WordIn] = Field(..., max_length=200)


class Found(BaseModel):
    text: str
    lang: str | None
    path: list[int]  # the word up to the root


class CheckOut(BaseModel):
    found: list[Found]  # the words that descend from the root, in the order given
    unknown: list[str]  # words not in the graph at all
    nodes: dict[int, api.Node]


@router.post("/check", response_model=CheckOut)
def check(body: CheckIn, db: sqlite3.Connection = Depends(api.get_db)):
    found, unknown, used = [], [], {body.root}
    for w in body.words:
        text = api.normalize(w.text)
        lang, ids = api.best_language(db, text, w.lang)
        if not ids:
            unknown.append(text)
            continue
        tree = climb(db, ids, CHECK_DEPTH)
        if body.root in tree:
            way = [n for n, _ in path(tree, body.root)]
            used.update(way)
            found.append(Found(text=text, lang=lang, path=way))
    return CheckOut(found=found, unknown=unknown, nodes=api.nodes_for(db, used))


# ---------- Birthplace ----------

class BirthplaceOut(BaseModel):
    word: Word
    born: int  # the oldest attested ancestor with a place: where the word was born
    journey: list[int]  # the word, then each ancestor back to there, with places
    km: float  # how far the word has travelled
    nodes: dict[int, api.Node]


MIN_TRAVEL_KM = 400  # nearer is too easy: Old English to English stays in England


def km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a.lat, a.lon, b.lat, b.lon))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


@router.get("/birthplace", response_model=BirthplaceOut)
def birthplace(lang: str | None = None, seed: int | None = None,
               db: sqlite3.Connection = Depends(api.get_db)):
    if not api.has_table(db, "language_geo"):
        raise HTTPException(503, "run pipeline/geo.py")
    rng = random.Random(seed)
    lang = game_language(lang, rng)
    words = list(common_words(db, lang))
    rng.shuffle(words)
    for tid, word in words[:TRIES * 3]:
        if not plain(word):
            continue
        steps = [tid] + [n for n, kind in lineage(db, tid) if kind != "root"]
        nodes = api.nodes_for(db, steps)
        placed = [n for n in steps if n in nodes and nodes[n].lat is not None]
        attested = [n for n in placed if not nodes[n].reconstructed]
        if len(attested) < 2:
            continue
        born = attested[-1]
        if nodes[born].word.lower() == word.lower():
            continue  # dental <- Middle French dental: nothing to see on the way
        distance = km(nodes[tid], nodes[born]) if nodes[tid].lat is not None else 0
        if distance < MIN_TRAVEL_KM:
            continue
        journey = placed[:placed.index(born) + 1]
        api.log.info(f"{api._c('1;33', 'birth')}  {word} ({lang}) ← {nodes[born].word} "
                     f"({nodes[born].language}), {distance:.0f} km")
        return BirthplaceOut(word=as_word(db, tid), born=born, journey=journey, km=distance,
                             nodes=nodes)
    raise HTTPException(404, "no word found")
