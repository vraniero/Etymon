"""Root Chain, the word game: each word played must share an ancestor with the one before.

    POST /chain/reply  {"word": {"text": "padre", "lang": "it"}, "used": ["father", "padre"],
                        "avoid_root": 123, "level": "normal"}
                       -> the app's move: a word that meets the last one at a shared
                          ancestor, not played before, not through the root just used

Players' moves are checked by the app with POST /scene (two words, one shared root), so
a move and the network drawn for it are the same answer. This only chooses the app's word.
"""
import random
import sqlite3
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import app as api
from connect import MAX_COST, climb, meetings
from query import MODERN

router = APIRouter(prefix="/chain")

# How the app plays at each level: how far up the last word it looks for an ancestor to
# branch from, how common its words are (Zipf; 3 = once per million words), and whether
# it keeps to the last word's language and English or ranges over every language; how
# close its links are (cost of both paths to the shared ancestor; a root alone costs 6).
LEVELS = {
    "easy": {"climb": 8, "min_zipf": 3.5, "any_language": False, "max_distance": 6},
    "normal": {"climb": 12, "min_zipf": 2.5, "any_language": False, "max_distance": 9},
    "hard": {"climb": 16, "min_zipf": 1.0, "any_language": True, "max_distance": 14},
}
ANCESTORS_TRIED = 12  # nearest first
CHILDREN_PER_ANCESTOR = 40  # per node, commonest modern words first
DESCENT_GENERATIONS = 3
POOL_ENOUGH = 300  # stop looking at further ancestors
CANDIDATES_CHECKED = 30


class WordIn(BaseModel):
    text: str
    lang: str | None = None


class ReplyIn(BaseModel):
    word: WordIn
    used: list[str] = Field(default_factory=list, max_length=500)  # words played, any case
    avoid_root: int | None = None  # the meeting point of the last link: go elsewhere
    level: Literal["easy", "normal", "hard"] = "normal"
    lang: str | None = None  # the game's language: the app plays only in it
    seed: int | None = None  # for repeatable games (tests)


class ReplyOut(BaseModel):
    text: str
    lang: str
    meet: int  # the shared ancestor the app has in mind
    candidates: int  # how many words it could have played


def descend(db, ancestor, seen, keep, generations=None):
    """Modern words below an ancestor, a few generations down (pater -> paternus ->
    paternal), commonest first at each step: {term id: (word, lang, zipf)} for those
    `keep(word, lang, zipf)` accepts. `seen` is updated, so ancestors share no words."""
    found = {}
    marks = ",".join("?" * len(api.DESCENT))
    frontier = [ancestor]
    for _ in range(generations or DESCENT_GENERATIONS):
        below = []
        for parent in frontier:
            for src, word, wlang, zipf, entry in db.execute(
                    f"SELECT t.id, t.word, t.lang, coalesce(t.zipf, 0), t.has_entry "
                    f"FROM edge e JOIN term t ON t.id=e.src "
                    f"WHERE e.dst=? AND e.kind IN ({marks}) "
                    f"ORDER BY (t.lang IN ({','.join('?' * len(MODERN))})) DESC, "
                    f"coalesce(t.zipf, 0) DESC LIMIT ?",
                    (parent, *api.DESCENT, *MODERN, CHILDREN_PER_ANCESTOR)):
                if src in seen:
                    continue
                seen.add(src)
                below.append(src)
                if wlang in MODERN and entry and plain(word):
                    zipf = frequency(db, src, wlang, zipf)
                    if keep(word, wlang, zipf):
                        found[src] = (word, wlang, zipf)
        frontier = below
    return found


def plain(word):
    """A word a player could type: no phrases, affixes, abbreviations or reconstructions."""
    return (" " not in word and "-" not in word and not word.startswith(("*", "-")) and not word.endswith("-")
            and len(word) > 1 and not any(c.isdigit() for c in word) and word != word.upper()
            and not word[0].isupper())  # proper nouns: Paterson isn't a fair move


@router.post("/reply", response_model=ReplyOut)
def reply(body: ReplyIn, db: sqlite3.Connection = Depends(api.get_db)):
    level = LEVELS[body.level]
    rng = random.Random(body.seed)
    lang, ids = api.best_language(db, api.normalize(body.word.text), body.word.lang)
    if not ids:
        raise HTTPException(404, "word not found")
    used = {u.strip().lower() for u in body.used} | {body.word.text.strip().lower()}
    if body.lang:
        langs = {body.lang}
    else:
        langs = None if level["any_language"] else {lang, "en"}
    near = climb(db, ids, MAX_COST)
    # At the level first; with nothing there, wider: rarer words, older ancestors (a
    # smaller language has few common words close by).
    pool, checked = {}, []
    for wide in (False, True):
        settings = {**level, **(WIDER if wide else {})}
        pool = candidates(db, ids, body, settings, used, langs)
        checked = verified(db, ids, body, pool, near, rng)
        if checked:
            break
    if not checked:
        api.log.info(f"{api._c('1;33', 'chain')}  {body.word.text} → {api._c('2', 'nothing found')}")
        raise HTTPException(404, "no word left to play")
    checked.sort()
    reach = settings["max_distance"]
    close = [c for c in checked if c[0] <= reach] or checked[:1]
    distance, tid, meet = close[0] if body.level == "easy" else rng.choice(close)
    word, wlang, _ = pool[tid]
    api.log.info(f"{api._c('1;33', 'chain')}  {body.word.text} → {word} ({wlang})  "
                 f"{api._c('2', f'distance {distance:g}, {len(pool)} candidates, {body.level}')}")
    return ReplyOut(text=word, lang=wlang, meet=meet, candidates=len(pool))


# How the app widens its search when nothing is found at its level.
WIDER = {"climb": 20, "min_zipf": 0.0, "max_distance": 20, "ancestors": 24, "generations": 5}


def candidates(db, ids, body, level, used, langs):
    """Modern words below the last word's nearest ancestors: {term id: (word, lang, zipf)}."""
    up = climb(db, ids, level["climb"])
    # ancestors to branch from, nearest first; never the root the last link went through
    ancestors = sorted((cost, n) for n, (cost, _, _) in up.items()
                       if n not in ids and n != body.avoid_root)[:level.get("ancestors", ANCESTORS_TRIED)]
    pool = {}
    seen = set(ids) | {n for _, n in ancestors}
    for _, anc in ancestors:
        pool.update(descend(db, anc, seen, lambda word, wlang, zipf: (
            word.lower() not in used and zipf >= level["min_zipf"]
            and (not langs or wlang in langs) and script(word) == script(body.word.text)),
            generations=level.get("generations")))
        if len(pool) >= POOL_ENOUGH:
            break
    return pool


def verified(db, ids, body, pool, near, rng):
    """Some at random among the commoner candidates, each checked the way the app checks
    a move (POST /scene searches at MAX_COST first): it must meet the last word, and not
    at the root to avoid. [(distance, term id, meet)]"""
    ranked = sorted(pool, key=lambda t: -pool[t][2])[:CANDIDATES_CHECKED * 2]
    rng.shuffle(ranked)
    checked = []
    for tid in ranked[:CANDIDATES_CHECKED]:
        word, wlang, _ = pool[tid]
        # forms of one word don't count: the app won't accept them as a link either
        if set(api.resolve(db, wlang, word)) & set(ids):
            continue
        found = meetings(near, climb(db, [tid], MAX_COST), 1)
        if found and found[0][1] != body.avoid_root and sensible_meet(db, found[0][1]):
            checked.append((found[0][0], tid, found[0][1]))
    return checked


def sensible_meet(db, node):
    """Not a stray one-letter node the data sometimes has as an ancestor."""
    row = db.execute("SELECT word FROM term WHERE id=?", (node,)).fetchone()
    return bool(row) and len(row[0].strip("*-")) > 1


class StartOut(BaseModel):
    text: str
    lang: str


# Opening words: common, but not function words (which reach everything through PIE),
# with a few generations of ancestry to branch from.
START_ZIPF = (4.0, 5.6)
START_ANCESTORS = 3


@router.get("/start", response_model=StartOut)
def start(lang: str, seed: int | None = None, db: sqlite3.Connection = Depends(api.get_db)):
    """An opening word in the game's language."""
    if lang not in MODERN:
        raise HTTPException(404, "unknown language")
    rng = random.Random(seed)
    rows = list(common_words(db, lang))
    rng.shuffle(rows)
    for tid, word in rows[:60]:
        if plain(word) and len(word) > 2 and len(climb(db, [tid], MAX_COST)) > START_ANCESTORS:
            return StartOut(text=word, lang=lang)
    raise HTTPException(404, "no opening word")


_common = {}


def common_words(db, lang):
    """(id, word) of a language's common words with an etymology; read once (a scan of
    the language takes a couple of seconds)."""
    if lang not in _common:
        estimated = estimates(db, lang)
        if estimated is None:
            rows = db.execute(
                "SELECT t.id, t.word FROM term t WHERE t.lang=? AND t.has_entry=1 "
                "AND t.zipf BETWEEN ? AND ? AND EXISTS (SELECT 1 FROM edge e WHERE e.src=t.id)",
                (lang, *START_ZIPF))
        else:
            low, high = START_ZIPF
            ids = [t for t, z in estimated.items() if low <= z <= high]
            rows = db.execute(
                f"SELECT t.id, t.word FROM term t WHERE t.id IN ({','.join('?' * len(ids))}) "
                f"AND t.has_entry=1 AND EXISTS (SELECT 1 FROM edge e WHERE e.src=t.id)", ids) \
                if ids else []
        _common[lang] = tuple(rows)
    return _common[lang]


_estimates = {}


def estimates(db, lang):
    """For a language with no frequency list (Belarusian, Estonian): each word's
    frequency guessed from its English meaning (хата, "house": as common as house).
    None for a language that has real frequencies."""
    if lang not in _estimates:
        has = db.execute("SELECT 1 FROM term WHERE lang=? AND zipf IS NOT NULL LIMIT 1",
                         (lang,)).fetchone()
        if has:
            _estimates[lang] = None
        else:
            # two indexed lookups; one join lets SQLite pick a slow order
            meanings = db.execute(
                "SELECT term, key FROM meaning WHERE term IN "
                "(SELECT id FROM term WHERE lang=?)", (lang,)).fetchall()
            keys = list({k for _, k in meanings})
            english = {}
            for i in range(0, len(keys), 500):
                part = keys[i:i + 500]
                english.update(db.execute(
                    f"SELECT word, zipf FROM term WHERE lang='en' AND zipf IS NOT NULL "
                    f"AND word IN ({','.join('?' * len(part))})", part))
            guess = {}
            for term, key in meanings:
                if key in english:
                    guess[term] = max(guess.get(term, 0.0), english[key])
            _estimates[lang] = guess
    return _estimates[lang]


def frequency(db, tid, lang, zipf):
    """A word's Zipf frequency: its own, or the estimate where its language has none."""
    estimated = estimates(db, lang)
    return zipf if estimated is None else estimated.get(tid, 0.0)


def script(word):
    """"cyrl" or "latn": Serbo-Croatian is written in both, and a game keeps to one."""
    return "cyrl" if any("\u0400" <= c <= "\u04ff" for c in word) else "latn"
