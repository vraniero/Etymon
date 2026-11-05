"""Explore the network around a word: its ancestry, roots and relatives in other languages.

Usage: .venv/bin/python query.py it padri [db.sqlite]
"""
import sqlite3
import sys
from pathlib import Path

from modern import MODERN  # noqa: F401  (re-exported for the backend)

ANCESTRY = ("inherited", "borrowed", "learned", "calque", "semantic_loan", "derived")


def resolve(db, lang, word):
    """Term ids for a surface word. A word with its own etymology is itself (notte, even
    though one sense makes it short for buonanotte); otherwise the lemma(s) it is a form
    of (padri -> padre), plus its bare entry if it has one."""
    own = [r[0] for r in db.execute(
        "SELECT id FROM term t WHERE lang=? AND word=? AND has_entry=1 AND "
        "EXISTS (SELECT 1 FROM edge WHERE src=t.id)", (lang, word))]
    if own:
        return own
    rows = [r[0] for r in db.execute("SELECT lemma FROM form WHERE lang=? AND form=?",
                                     (lang, word))]
    if not rows:
        rows = [r[0] for r in db.execute(
            "SELECT id FROM term WHERE lang=? AND word=? AND has_entry=1", (lang, word))]
    if not rows and word != word.lower():
        return resolve(db, lang, word.lower())
    return list(dict.fromkeys(rows))


def label(db, tid):
    lang, word, gloss = db.execute(
        "SELECT t.lang||' ('||coalesce(l.name,t.lang)||')', t.word, t.gloss "
        "FROM term t LEFT JOIN language l ON l.code=t.lang WHERE t.id=?", (tid,)).fetchone()
    return f"{word} [{lang}]" + (f" — {gloss[:60]}" if gloss else "")


def ancestors(db, tid, depth=8):
    """Walk the source chain; returns [(id, kind, inferred)] nearest first."""
    out, seen, frontier = [], {tid}, [tid]
    for _ in range(depth):
        nxt = []
        for t in frontier:
            for dst, kind, inferred in db.execute(
                    f"SELECT dst, kind, inferred FROM edge WHERE src=? AND kind IN "
                    f"({','.join('?' * len(ANCESTRY))}) ORDER BY inferred, "
                    f"instr('inherited borrowed learned calque semantic_loan derived', kind)",
                    (t, *ANCESTRY)):
                if dst not in seen:
                    seen.add(dst)
                    out.append((dst, kind, inferred))
                    nxt.append(dst)
        frontier = nxt
    return out


def descendants_in_modern(db, tid, depth=6, exclude=()):
    """Modern-language words that descend from (or have as root) the given term."""
    found, seen, frontier = {}, {tid}, [tid]
    for _ in range(depth):
        nxt = []
        for t in frontier:
            for src, lang, kind in db.execute(
                    "SELECT e.src, t.lang, e.kind FROM edge e JOIN term t ON t.id=e.src "
                    "WHERE e.dst=? AND e.kind NOT IN ('cognate','doublet','component')", (t,)):
                if src in seen:
                    continue
                seen.add(src)
                nxt.append(src)
                if lang in MODERN and src not in exclude:
                    found[src] = kind
        frontier = nxt
    return found


def main(lang, word, db_path):
    db = sqlite3.connect(db_path)
    ids = resolve(db, lang, word)
    if not ids:
        print("not found")
        return
    for tid in ids:
        print("\n==", label(db, tid))
        anc = ancestors(db, tid)
        print("ancestry:")
        for a, kind, inferred in anc:
            print(f"   {'~' if inferred else ' '}{kind:>13} -> {label(db, a)}")
        roots = [r for (r,) in db.execute("SELECT dst FROM edge WHERE src=? AND kind='root'", (tid,))]
        for r in roots:
            print(f"    {'root':>13} -> {label(db, r)}")
        print("cognates:", ", ".join(label(db, c).split(" — ")[0] for (c,) in db.execute(
            "SELECT CASE WHEN src=? THEN dst ELSE src END FROM edge "
            "WHERE kind='cognate' AND (src=? OR dst=?) LIMIT 15", (tid, tid, tid))))
        # relatives: other modern words reached back down from the deepest ancestors and roots
        print("relatives through shared ancestors/roots:")
        seen = {tid}
        for h in [a for a, _, _ in anc] + roots:
            relatives = descendants_in_modern(db, h, exclude=seen)
            if not relatives:
                continue
            seen.update(relatives)
            print(f"  via {label(db, h).split(' — ')[0]}")
            by_lang = {}
            for r in relatives:
                l, w = db.execute("SELECT lang, word FROM term WHERE id=?", (r,)).fetchone()
                by_lang.setdefault(l, []).append(w)
            for l in MODERN:
                if by_lang.get(l):
                    print(f"      {l}: {', '.join(sorted(by_lang[l])[:15])}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2],
         sys.argv[3] if len(sys.argv) > 3 else Path(__file__).parent / "data" / "etymon.sqlite")
