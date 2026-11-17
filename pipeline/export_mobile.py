"""Prune the full graph to an app-sized SQLite bundle.

Keeps modern-language words above a frequency threshold or with an etymology of their own, everything they lead to
upward (ancestors, roots, components — at any depth), all edges among the kept
terms, inflected forms common enough to be seen in the wild, and what the backend needs
around them: English meanings (same-meaning links), where languages were spoken, and
which affixes the search may climb through. Not the raw etymology text, which nothing
reads, and glosses cut to --gloss characters.

The backend runs on this file alone, and its tests pass against it:
    cd ../backend && ETYMON_DB=../pipeline/data/etymon-mobile.sqlite .venv/bin/python -m pytest

Usage: .venv/bin/python export_mobile.py [--zipf 2.5] [--gloss 160] [full.sqlite] [out.sqlite]
"""
import argparse
import sqlite3
from pathlib import Path

from modern import MODERN, has_frequency, zipf

DATA = Path(__file__).parent / "data"
UPWARD = ("inherited", "derived", "borrowed", "learned", "calque", "semantic_loan",
          "root", "component")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zipf", type=float, default=2.5,
                    help="min word frequency (Zipf scale; 3 = once per million words)")
    ap.add_argument("--gloss", type=int, default=160,
                    help="keep at most this many characters of each gloss (0: none)")
    ap.add_argument("src", nargs="?", default=DATA / "etymon.sqlite")
    ap.add_argument("out", nargs="?", default=DATA / "etymon-mobile.sqlite")
    args = ap.parse_args()

    out = Path(args.out)
    out.unlink(missing_ok=True)
    db = sqlite3.connect(out)
    db.execute("ATTACH ? AS full", (str(args.src),))
    db.executescript("""
        CREATE TEMP TABLE keep (id INTEGER PRIMARY KEY);
    """)
    ranked = [l for l in MODERN if l in has_frequency()]
    db.execute(f"""
        INSERT INTO keep SELECT id FROM full.term
        WHERE lang IN ({','.join('?' * len(ranked))}) AND has_entry=1 AND zipf >= ?
    """, (*ranked, args.zipf))
    # and, however rare, every lemma whose entry gives an ancestry: a rare word on a sign
    # (paternalistic) still connects; one without would only show its meaning
    db.execute(f"""
        INSERT OR IGNORE INTO keep SELECT t.id FROM full.term t
        WHERE t.lang IN ({','.join('?' * len(MODERN))}) AND t.has_entry=1
          AND EXISTS (SELECT 1 FROM full.edge e WHERE e.src=t.id AND e.inferred=0
                      AND e.kind != 'root')
          AND NOT EXISTS (SELECT 1 FROM full.form f WHERE f.lang=t.lang AND f.form=t.word)
    """, MODERN)
    seeds = db.execute("SELECT count(*) FROM keep").fetchone()[0]

    # upward closure: ancestors of ancestors, roots of components, ...
    up = {}
    for src, dst in db.execute(
            f"SELECT src, dst FROM full.edge WHERE kind IN ({','.join('?' * len(UPWARD))})",
            UPWARD):
        up.setdefault(src, []).append(dst)
    keep = {i for (i,) in db.execute("SELECT id FROM keep")}
    frontier = list(keep)
    while frontier:
        nxt = [d for s in frontier for d in up.get(s, ()) if d not in keep]
        keep.update(nxt)
        frontier = nxt
    db.executemany("INSERT OR IGNORE INTO keep VALUES (?)", ((i,) for i in keep))

    db.executescript("""
        CREATE TABLE family   AS SELECT * FROM full.family;
        CREATE TABLE language AS SELECT * FROM full.language;
        CREATE TABLE language_geo AS SELECT * FROM full.language_geo;
        CREATE TABLE term (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, word TEXT NOT NULL,
                           gloss TEXT, zipf REAL, has_entry INTEGER);
        CREATE TABLE open_affix (id INTEGER PRIMARY KEY);
        INSERT INTO open_affix SELECT id FROM full.open_affix WHERE id IN (SELECT id FROM keep);
        -- a rowid table: the backend lists a word's meanings in rowid order
        CREATE TABLE meaning (term INTEGER NOT NULL, key TEXT NOT NULL,
                              PRIMARY KEY (term, key));
        CREATE TABLE edge (src INTEGER NOT NULL, dst INTEGER NOT NULL, kind TEXT NOT NULL,
                           inferred INTEGER NOT NULL, PRIMARY KEY (src, dst, kind)) WITHOUT ROWID;
        CREATE TABLE form (lang TEXT NOT NULL, form TEXT NOT NULL, lemma INTEGER NOT NULL,
                           PRIMARY KEY (lang, form, lemma)) WITHOUT ROWID;
    """)

    cut = args.gloss
    gloss = ("CASE WHEN length(gloss) > ? THEN substr(gloss, 1, ?) || '…' ELSE gloss END"
             if cut else "NULL")
    db.execute(f"""
        INSERT INTO term SELECT id, lang, word, {gloss}, zipf, has_entry
        FROM full.term WHERE id IN (SELECT id FROM keep)
    """, (cut, cut - 1) if cut else ())
    # meanings in the order the full graph lists them (the first is the main one)
    db.execute("""
        INSERT INTO meaning SELECT term, key FROM full.meaning
        WHERE term IN (SELECT id FROM keep) ORDER BY rowid
    """)

    # filtered in Python: SQLite's planner turns the two-sided IN filter into a pair probe
    db.executemany("INSERT INTO edge VALUES (?,?,?,?)",
                   (r for r in db.execute(
                       "SELECT * FROM full.edge WHERE kind NOT IN ('cognate', 'doublet')"
                   ).fetchall() if r[0] in keep and r[1] in keep))  # nothing climbs those

    # inflected forms, only those frequent enough to plausibly show up on a sign or in speech
    rows = db.execute("""
        SELECT lang, form, lemma FROM full.form
    """).fetchall()
    db.executemany("INSERT INTO form VALUES (?,?,?)",
                   (r for r in rows
                    if r[0] in has_frequency() and r[2] in keep
                    and zipf(r[1], r[0]) >= args.zipf - 0.5))

    db.executescript("""
        CREATE UNIQUE INDEX term_lang_word ON term(lang, word);
        CREATE INDEX edge_dst ON edge(dst);
        CREATE INDEX meaning_key ON meaning(key);
    """)
    db.commit()
    db.execute("DETACH full")
    db.execute("VACUUM")
    counts = {t: db.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
              for t in ("term", "edge", "form", "meaning")}
    db.close()
    print(f"seeds: {seeds:,}  " + "  ".join(f"{k}: {v:,}" for k, v in counts.items()))
    print(f"{out.name}: {out.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
