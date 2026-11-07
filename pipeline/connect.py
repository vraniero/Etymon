"""Find what two words have in common: their nearest shared ancestors and the paths to them.

This is the core question the app asks of a scene — "padre" on one sign and
"paternalistic" on another meet at Latin *pater*.

Usage: .venv/bin/python connect.py it padre en paternalistic [db.sqlite]
"""
import heapq
import sqlite3
import sys
from pathlib import Path

from query import label, resolve

# Cost of climbing one edge. Stated links are cheaper than ones read off a chain, and
# meeting at a shared word beats meeting only at a reconstructed root.
COST = {"inherited": 1.0, "borrowed": 1.0, "learned": 1.0, "calque": 1.2,
        "semantic_loan": 1.5, "derived": 1.0, "component": 1.0, "root": 6.0}
INFERRED_PENALTY = 0.5
MAX_COST = 16
TOP_LANGUAGES = {"ine-pro"}


def is_affix(word):
    """"-ism", "re-", "*-tḗr": shared by thousands of words, so not a meaningful connection.
    Reconstructed stems and roots are cited with a trailing hyphen (*twai-, *peh₂-) and
    are real ancestors, not affixes."""
    if word.startswith("*"):
        return word[1:].startswith("-")
    return word.startswith("-") or word.endswith("-")


_open_cache = {}


def open_affixes(db):
    """Affixes the search may pass through: combining forms of real words (Italian bio-,
    from Greek βίος), listed by refine.py. Empty for a database built before it."""
    path = db.execute("PRAGMA database_list").fetchone()[2]
    if path and path in _open_cache:
        return _open_cache[path]
    try:
        ids = {i for (i,) in db.execute("SELECT id FROM open_affix")}
    except sqlite3.OperationalError:
        ids = set()
    if path:
        _open_cache[path] = ids
    return ids


def closed(db, node, word):
    """A node the search doesn't climb into: an affix shared by too much to mean anything."""
    return is_affix(word) and node not in open_affixes(db)


def climb(db, starts, max_cost=MAX_COST):
    """Dijkstra up the source edges from the start ids, no further than max_cost (the
    search depth). Returns {id: (cost, parent, kind)}."""
    best = {s: (0.0, None, None) for s in starts}
    heap = [(0.0, s) for s in starts]
    top = set()  # Proto-Indo-European nodes: climbed only to what they are built from
    kinds = tuple(COST)
    while heap:
        cost, t = heapq.heappop(heap)
        if cost > best[t][0]:
            continue
        for dst, kind, inferred, word, lang in db.execute(
                f"SELECT e.dst, e.kind, e.inferred, d.word, d.lang FROM edge e "
                f"JOIN term d ON d.id=e.dst "
                f"WHERE e.src=? AND e.kind IN ({','.join('?' * len(kinds))})", (t, *kinds)):
            if closed(db, dst, word):
                continue
            if t in top and kind != "component":
                # PIE is as far back as the data goes; its entries cite other roots as
                # loosely related (*upo ... *wert- ... *(s)penh₁-), which is not descent.
                # What a PIE word is built from is stated, though: *septm̥mós (seventh)
                # = *septḿ̥ (seven) + *-ós
                continue
            c = cost + COST[kind] + INFERRED_PENALTY * inferred
            if c > max_cost:
                continue
            if dst not in best or c < best[dst][0]:
                best[dst] = (c, t, kind)
                heapq.heappush(heap, (c, dst))
            if lang in TOP_LANGUAGES:
                top.add(dst)
    return best


def path(tree, node):
    out = []
    while node is not None:
        _, parent, kind = tree[node]
        out.append((node, kind))
        node = parent
    return out[::-1]  # start word first, meeting point last


LINEAGE_ORDER = ("inherited", "derived", "learned", "borrowed", "calque", "semantic_loan",
                 "component")


def lineage(db, node, depth=12):
    """The chain above a meeting point, up to the oldest known ancestor and its root:
    pater -> *patēr -> *ph₂tḗr -root-> *peh₂-. Follows the most direct link at each step."""
    out, seen = [], {node}
    for _ in range(depth):
        row = db.execute(
            f"SELECT e.dst, e.kind, d.word FROM edge e JOIN term d ON d.id=e.dst "
            f"WHERE e.src=? AND e.kind IN ({','.join('?' * len(LINEAGE_ORDER))}) "
            f"ORDER BY e.inferred, instr('{' '.join(LINEAGE_ORDER)}', e.kind)",
            (node, *LINEAGE_ORDER)).fetchall()
        row = next((r for r in row if r[0] not in seen and not closed(db, r[0], r[2])), None)
        if row is None:
            break
        node = row[0]
        seen.add(node)
        out.append((node, row[1]))
    # reconstructed roots stated on any word of the line (often only on the modern entry)
    roots = db.execute(
        f"SELECT DISTINCT dst FROM edge WHERE kind='root' AND src IN "
        f"({','.join('?' * len(seen))})", tuple(seen)).fetchall()
    out += [(r, "root") for (r,) in roots if r not in seen]
    return out


def ancestry(db, node, depth=12, limit=40):
    """Every ancestor above a node, not one line: a compound has one per part. football
    goes back to foot and to ball (and Middle English fotbal, itself fot + bal); Handschuh
    to Hand and Schuh. Each node follows its most direct link, as `lineage` does, and also
    every part it is stated to be built from.

    Returns (node, kind, child) triples, child being the node it is an ancestor of: the
    main line first (the same as `lineage`), then the other branches, depth first. A node
    reached twice (fotbal's fot is also foot's) appears once; the second link to it is
    listed again with its own child. At most `limit` steps, `depth` along any branch."""
    out, seen, linked = [], {node}, set()
    marks = ",".join("?" * len(LINEAGE_ORDER))

    def parents(n, top):
        rows = db.execute(
            f"SELECT e.dst, e.kind, e.inferred, d.word, d.lang FROM edge e "
            f"JOIN term d ON d.id=e.dst WHERE e.src=? AND e.kind IN ({marks}) "
            f"ORDER BY e.inferred, instr('{' '.join(LINEAGE_ORDER)}', e.kind)",
            (n, *LINEAGE_ORDER)).fetchall()
        # as in climb: a Proto-Indo-European word goes on only to what it is built from
        rows = [r for r in rows if r[0] != n and not closed(db, r[0], r[3])
                and (not top or r[1] == "component")]
        parts = [r for r in rows[1:] if r[1] == "component" and not r[2] and r[0] != rows[0][0]]
        return [(d, k, lang) for d, k, _, _, lang in rows[:1] + parts]

    def walk(n, top, left, stack):
        for dst, kind, lang in parents(n, top):
            if len(out) >= limit:
                return
            if dst in stack or (n, dst) in linked:
                continue  # a cycle in the data, or a link already listed
            linked.add((n, dst))
            out.append((dst, kind, n))
            if dst not in seen:
                seen.add(dst)
                if left > 1:
                    walk(dst, lang in TOP_LANGUAGES, left - 1, stack | {dst})

    start = db.execute("SELECT lang FROM term WHERE id=?", (node,)).fetchone()
    walk(node, bool(start) and start[0] in TOP_LANGUAGES, depth, {node})
    # reconstructed roots stated on any word above (often only on the modern entry)
    for n in [node] + [d for d, _, _ in out]:
        for (r,) in db.execute("SELECT DISTINCT dst FROM edge WHERE kind='root' AND src=?", (n,)):
            if r not in seen and len(out) < limit + 4:
                seen.add(r)
                out.append((r, "root", n))
    return out


def connect(db, a_ids, b_ids, limit=3):
    return meetings(climb(db, a_ids), climb(db, b_ids), limit)


def meetings(up_a, up_b, limit=3):
    """Nearest shared ancestors of two climbed trees, as (distance, node, path_a, path_b)."""
    shared = sorted((up_a[n][0] + up_b[n][0], n) for n in up_a.keys() & up_b.keys())
    chosen = []
    for total, n in shared:
        # skip meetings that sit above one already chosen (pater beats *ph₂tḗr above it)
        if any(n in {p for p, _ in path(up_a, m)} | {p for p, _ in path(up_b, m)} or
               m in {p for p, _ in path(up_a, n)} for _, m in chosen):
            continue
        chosen.append((total, n))
        if len(chosen) == limit:
            break
    return [(total, n, path(up_a, n), path(up_b, n)) for total, n in chosen]


def show(db, p):
    parts = [label(db, p[0][0]).split(" — ")[0]]
    for node, kind in p[1:]:
        parts.append(f"-{kind}-> {label(db, node).split(' — ')[0]}")
    return " ".join(parts)


def main(lang_a, word_a, lang_b, word_b, db_path):
    db = sqlite3.connect(db_path)
    a, b = resolve(db, lang_a, word_a), resolve(db, lang_b, word_b)
    for name, ids in ((word_a, a), (word_b, b)):
        if not ids:
            sys.exit(f"{name}: not found")
    results = connect(db, a, b)
    if not results:
        print("no shared ancestor found")
    for total, n, pa, pb in results:
        print(f"\n== meet at {label(db, n)}   (distance {total:g})")
        print("  ", show(db, pa))
        print("  ", show(db, pb))
        above = lineage(db, n)
        if above:
            print("   and deeper:", show(db, [(n, None)] + above))


if __name__ == "__main__":
    args = sys.argv[1:]
    main(*args[:4], args[4] if len(args) > 4 else Path(__file__).parent / "data" / "etymon.sqlite")
