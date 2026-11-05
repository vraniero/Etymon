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


def is_affix(word):
    """"-ism", "re-", "*-tḗr": shared by thousands of words, so not a meaningful connection.
    Reconstructed stems and roots are cited with a trailing hyphen (*twai-, *peh₂-) and
    are real ancestors, not affixes."""
    if word.startswith("*"):
        return word[1:].startswith("-")
    return word.startswith("-") or word.endswith("-")


def climb(db, starts):
    """Dijkstra up the source edges from the start ids. Returns {id: (cost, parent, kind)}."""
    best = {s: (0.0, None, None) for s in starts}
    heap = [(0.0, s) for s in starts]
    kinds = tuple(COST)
    while heap:
        cost, t = heapq.heappop(heap)
        if cost > best[t][0] or cost > MAX_COST:
            continue
        for dst, kind, inferred, word in db.execute(
                f"SELECT e.dst, e.kind, e.inferred, d.word FROM edge e JOIN term d ON d.id=e.dst "
                f"WHERE e.src=? AND e.kind IN ({','.join('?' * len(kinds))})", (t, *kinds)):
            if is_affix(word):
                continue
            c = cost + COST[kind] + INFERRED_PENALTY * inferred
            if dst not in best or c < best[dst][0]:
                best[dst] = (c, t, kind)
                heapq.heappush(heap, (c, dst))
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
        row = next((r for r in row if r[0] not in seen and not is_affix(r[2])), None)
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
