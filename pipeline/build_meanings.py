"""Add semantic links to the graph: which words mean the same thing across languages.

Every non-English Wiktionary entry is defined in English ("aperto: open", "Nacht:
night"), so English works as the pivot: each term gets meaning keys — its parsed
definition, or for English words the headword itself — and words that share a key are
translations of each other (it aperto = en open = de offen = fr ouvert).

Adds table meaning(term, key) to the graph database in place.

Usage: .venv/bin/python build_meanings.py [etymon.sqlite]
"""
import re
import sqlite3
import sys
from pathlib import Path

from modern import MODERN

DATA = Path(__file__).parent / "data"
MAX_KEYS = 4
MAX_WORDS = 3

# "feminine singular of aperto", "plural of padre": forms resolve to their lemma instead
FORM_OF = re.compile(r"\b(singular|plural|form|participle|person|tense|gerund|"
                     r"imperative|subjunctive|indicative|diminutive|augmentative|"
                     r"superlative|comparative|feminine|masculine|abbreviation|"
                     r"alternative|spelling|obsolete|archaic|misspelling|apocopic|"
                     r"contraction|initialism|acronym) of\b", re.I)
BRACKETS = re.compile(r"\([^)]*\)|“[^”]*”|\"[^\"]*\"|\[[^\]]*\]")
LEADING = re.compile(r"^(to|a|an|the|one's|someone's|something's)\s+", re.I)
WORDLIKE = re.compile(r"^[a-z][a-z' -]*[a-z]$")
GENERIC = {"thing", "something", "someone", "person", "one", "it", "that", "this",
           "used", "having", "being", "state", "act", "quality", "kind", "type"}


def keys_from_gloss(gloss):
    """English meaning keys from a definition: "open, unlocked (not closed)" -> open, unlocked."""
    if not gloss or FORM_OF.search(gloss):
        return []
    text = BRACKETS.sub("", gloss)
    keys = []
    for part in re.split(r"[;,]|\bor\b", text):
        part = LEADING.sub("", part.strip().strip(".:!?").lower()).strip()
        if (part and WORDLIKE.match(part) and len(part.split()) <= MAX_WORDS
                and part not in GENERIC and part not in keys):
            keys.append(part)
        if len(keys) == MAX_KEYS:
            break
    return keys


def main(db_path):
    db = sqlite3.connect(db_path)
    db.executescript("DROP TABLE IF EXISTS meaning;"
                     "CREATE TABLE meaning (term INTEGER NOT NULL, key TEXT NOT NULL,"
                     "                      PRIMARY KEY (term, key));")
    rows = []
    for tid, lang, word, gloss in db.execute(
            f"SELECT id, lang, word, gloss FROM term WHERE has_entry=1 AND "
            f"lang IN ({','.join('?' * len(MODERN))})", MODERN):
        if lang == "en":
            key = word.lower()
            if WORDLIKE.match(key) and len(key.split()) <= MAX_WORDS:
                rows.append((tid, key))
        else:
            rows.extend((tid, k) for k in keys_from_gloss(gloss))
    db.executemany("INSERT OR IGNORE INTO meaning VALUES (?,?)", rows)
    db.execute("CREATE INDEX meaning_key ON meaning(key)")
    db.commit()
    terms = db.execute("SELECT count(DISTINCT term) FROM meaning").fetchone()[0]
    print(f"meaning: {len(rows):,} keys on {terms:,} terms")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DATA / "etymon.sqlite")
