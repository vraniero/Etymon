"""Split the mobile graph into packs the app downloads one at a time: a core every install
gets, and one pack per modern language, fetched when the app first meets the language.

  core       every ancient term (Latin, Proto-Germanic, *PIE roots…), the edges up from
             them, languages, where they were spoken. Shared by every language, so stored
             once: packs climb into it.
  <lang>     the language's words, their inflected forms and English meanings, the edges
             up from them, and the modern words of other languages they lead to (Italian
             computer < English computer), with those words' own way up, so a line reaches
             the core even when that other language isn't installed.
  en is split by frequency: en (common words) and en-rare (the long tail).

Every pack is an SQLite file with the mobile schema (export_mobile.py). The app merges the
ones it has into one database with INSERT OR IGNORE: rows a pack shares with another are
identical, so the order doesn't matter. Merging all of them gives back the mobile graph.

Writes data/packs/<id>.sqlite, an asset-pack manifest for Apple-hosted Background Assets
under data/packs/manifests/, and data/packs/packs.json (ids, languages, sizes).

Usage: .venv/bin/python export_packs.py [--en-zipf 3.0] [--package] [mobile.sqlite] [out_dir]
"""
import argparse
import json
import sqlite3
import subprocess
from pathlib import Path

from modern import MODERN

DATA = Path(__file__).parent / "data"
TABLES = ("family", "language", "language_geo", "term", "edge", "form", "meaning", "open_affix")


def schema(src):
    """CREATE statements for every table and index of the mobile graph."""
    return [sql for (sql,) in src.execute(
        "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
        "ORDER BY type DESC")]  # tables before indexes


def write_pack(path, src_path, statements, terms, langs_for_rows, whole_tables=()):
    """A pack holding `terms`, the edges up from them, and the forms and meanings of the
    terms in `langs_for_rows`."""
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    for sql in statements:
        db.execute(sql)
    db.execute("ATTACH ? AS m", (str(src_path),))
    db.execute("CREATE TEMP TABLE ids (id INTEGER PRIMARY KEY)")
    db.executemany("INSERT INTO ids VALUES (?)", ((i,) for i in terms))
    for table in whole_tables:
        db.execute(f"INSERT INTO {table} SELECT * FROM m.{table}")
    db.execute("INSERT INTO term SELECT * FROM m.term WHERE id IN (SELECT id FROM ids)")
    db.execute("INSERT INTO edge SELECT * FROM m.edge WHERE src IN (SELECT id FROM ids)")
    db.execute("INSERT INTO open_affix SELECT * FROM m.open_affix WHERE id IN (SELECT id FROM ids)")
    marks = ",".join("?" * len(langs_for_rows))
    if langs_for_rows:
        own = (f"SELECT id FROM ids WHERE id IN (SELECT id FROM m.term WHERE lang IN ({marks}))")
        # meanings in rowid order: the backend lists a word's first meaning first
        db.execute(f"INSERT INTO meaning SELECT term, key FROM m.meaning WHERE term IN ({own}) "
                   f"ORDER BY rowid", langs_for_rows)
        db.execute(f"INSERT INTO form SELECT * FROM m.form WHERE lemma IN ({own})", langs_for_rows)
    db.commit()
    db.execute("DETACH m")
    db.execute("VACUUM")
    counts = {t: db.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
              for t in ("term", "edge", "form", "meaning")}
    db.close()
    return counts


def merge(out_path, pack_paths):
    """One database from several packs: what the app does with the packs it has."""
    out_path.unlink(missing_ok=True)
    db = sqlite3.connect(out_path)
    first = sqlite3.connect(pack_paths[0])
    for sql in schema(first):
        db.execute(sql)
    first.close()
    for path in pack_paths:
        db.execute("ATTACH ? AS p", (str(path),))
        for table in TABLES:
            db.execute(f"INSERT OR IGNORE INTO {table} SELECT * FROM p.{table}")
        db.commit()
        db.execute("DETACH p")
    db.close()


def compressed_size(path):
    """Bytes after LZFSE (what an asset pack download is close to)."""
    out = path.with_suffix(".lzfse")
    subprocess.run(["compression_tool", "-encode", "-a", "lzfse", "-i", path, "-o", out],
                   check=True)
    size = out.stat().st_size
    out.unlink()
    return size


def manifest(pack_id, file, essential=False):
    """An asset-pack manifest for ba-package (Apple-hosted: no userInfo)."""
    policy = ({"essential": {"installationEventTypes": ["firstInstallation", "subsequentUpdate"]}}
              if essential else {"onDemand": {}})
    return {"assetPackID": pack_id, "downloadPolicy": policy,
            "fileSelectors": [{"fileSource": file, "fileDestination": f"graph/{file}"}],
            "platforms": ["iOS"],
            "sourceRoot": ".."}  # relative to the manifest: the packs directory


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--en-zipf", type=float, default=3.0,
                    help="English words at least this frequent go in en, the rest in en-rare")
    ap.add_argument("--package", action="store_true",
                    help="also build the asset-pack archives (archives/<id>.aar) with "
                         "Xcode's ba-package, ready to upload to App Store Connect")
    ap.add_argument("src", nargs="?", default=DATA / "etymon-mobile.sqlite")
    ap.add_argument("out", nargs="?", default=DATA / "packs")
    args = ap.parse_args()
    src_path, out = Path(args.src), Path(args.out)
    (out / "manifests").mkdir(parents=True, exist_ok=True)
    src = sqlite3.connect(src_path)
    statements = schema(src)

    lang = dict(src.execute("SELECT id, lang FROM term"))
    zipf = dict(src.execute("SELECT id, coalesce(zipf, 0) FROM term WHERE lang='en'"))
    up = {}
    for s, d in src.execute("SELECT src, dst FROM edge"):
        up.setdefault(s, []).append(d)
    modern = set(MODERN)

    def closure(seeds, stop):
        seen, frontier = set(seeds), list(seeds)
        while frontier:
            frontier = [d for s in frontier for d in up.get(s, ()) if d not in seen and d not in stop]
            seen.update(frontier)
        return seen

    # core: every ancient term, and anything they in turn lead to
    core = closure({i for i, l in lang.items() if l not in modern}, set())
    groups = {}
    for i, l in lang.items():
        if l in modern and i not in core:
            key = l if l != "en" or zipf.get(i, 0) >= args.en_zipf else "en-rare"
            groups.setdefault(key, set()).add(i)

    # the core also holds the modern words ancient ones lead to: their forms and meanings too
    packs = [("core", core, list(MODERN), ("family", "language", "language_geo"))]
    packs += [(key, closure(ids, core), ["en" if key == "en-rare" else key], ())
              for key, ids in sorted(groups.items())]
    rows = []
    for key, terms, langs, whole in packs:
        file = f"{key}.sqlite"
        counts = write_pack(out / file, src_path, statements, terms, langs, whole)
        own = len(groups.get(key, ()))
        size, packed = (out / file).stat().st_size, compressed_size(out / file)
        pack_id = f"graph-{key}"
        (out / "manifests" / f"{pack_id}.json").write_text(
            json.dumps(manifest(pack_id, file, essential=key == "core"), indent=2) + "\n")
        rows.append({"id": pack_id, "file": f"graph/{file}",
                     "language": None if key == "core" else langs[0],
                     "words": own, "terms": counts["term"], "bytes": size,
                     "download_bytes": packed})
        print(f"{pack_id:16} terms {counts['term']:>9,}  edges {counts['edge']:>9,}  "
              f"{size / 1e6:6.1f} MB  download {packed / 1e6:5.1f} MB")
    (out / "packs.json").write_text(json.dumps({"packs": rows}, indent=1) + "\n")
    if args.package:
        (out / "archives").mkdir(exist_ok=True)
        for r in rows:
            subprocess.run(["xcrun", "ba-package", "package", "--quiet",
                            out / "manifests" / f"{r['id']}.json",
                            "-o", out / "archives" / f"{r['id']}.aar"], check=True)
        print(f"archives in {out / 'archives'}")
    total = sum(r["download_bytes"] for r in rows)
    print(f"all packs: download {total / 1e6:.0f} MB "
          f"(core {rows[0]['download_bytes'] / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
