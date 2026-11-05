"""Place every language of the graph on the map: where it was (or is) spoken.

Writes table language_geo (code, lat, lon, source) into the graph database, used by the
backend for the map view. Coordinates come from, in order:

  1. HOMELANDS below: hand-placed proto-languages and historical varieties Glottolog
     doesn't cover (Proto-Indo-European on the Pontic steppe, Late Latin in Rome...)
  2. Glottolog's point for the language, matched by ISO 639-3 code (Wiktionary's
     two-letter codes are mapped through the ISO 639-3 table)
  3. the language it is a variety of, its first ancestor, or its family's
     proto-language (Old Swedish -> Swedish, gmq-xxx -> Proto-Norse), recursively

Downloads (cached in data/geo/):
  Glottolog CLDF languages.csv    https://github.com/glottolog/glottolog-cldf (CC BY 4.0)
  SIL ISO 639-3 code table        https://iso639-3.sil.org

Usage: python3 geo.py [etymon.sqlite ...]   (default: the full and the mobile database)
"""
import csv
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

DATA = Path(__file__).parent / "data"
GEO = DATA / "geo"
SOURCES = {
    "glottolog.csv": "https://raw.githubusercontent.com/glottolog/glottolog-cldf/master/cldf/languages.csv",
    "iso-639-3.tab": "https://iso639-3.sil.org/sites/iso639-3/files/downloads/iso-639-3.tab",
}

# Reconstructed and historical languages, placed at their usual homeland or centre.
# Proto-language homelands are scholarly estimates; the map shows them as such.
HOMELANDS = {
    # Indo-European
    "ine-pro": (48.0, 40.0),      # Proto-Indo-European: Pontic-Caspian steppe
    "ine-bsl-pro": (54.0, 28.0),  # Proto-Balto-Slavic
    "bat-pro": (55.5, 25.0),      # Proto-Baltic
    "sla-pro": (51.5, 26.0),      # Proto-Slavic: Polesia / middle Dnieper
    "gem-pro": (56.0, 10.5),      # Proto-Germanic: southern Scandinavia, northern Germany
    "gmw-pro": (53.0, 9.0),       # Proto-West Germanic
    "gme-pro": (53.5, 18.0),      # Proto-East Germanic: Vistula
    "gmq-pro": (59.0, 12.0),      # Proto-Norse
    "itc-pro": (44.5, 12.0),      # Proto-Italic: northern Italy
    "cel-pro": (48.0, 8.0),       # Proto-Celtic: Hallstatt, upper Danube
    "cel-bry-pro": (52.0, -2.0),  # Proto-Brythonic
    "grk-pro": (39.5, 22.0),      # Proto-Hellenic
    "iir-pro": (52.0, 60.0),      # Proto-Indo-Iranian: Sintashta, southern Urals
    "ira-pro": (40.0, 63.0),      # Proto-Iranian: Bactria-Margiana
    "inc-pro": (30.0, 72.0),      # Proto-Indo-Aryan: Punjab
    "hyx-pro": (40.0, 44.0),      # Proto-Armenian
    "sqj-pro": (41.5, 20.0),      # Proto-Albanian
    "ine-ana-pro": (39.0, 33.0),  # Proto-Anatolian
    "ine-toc-pro": (42.0, 84.0),  # Proto-Tocharian: Tarim Basin
    # Latin and Romance varieties
    "la": (41.9, 12.5),           # Latin: Rome
    "la-lat": (41.9, 12.5), "la-vul": (41.9, 12.5), "la-med": (45.0, 8.0),
    "la-new": (48.0, 10.0), "la-cla": (41.9, 12.5), "la-ecc": (41.9, 12.5),
    "itc-ola": (41.9, 12.5),      # Old Latin
    "roa-opt": (41.5, -8.0),      # Old Galician-Portuguese
    "pro": (43.6, 3.9),           # Old Occitan
    "fro": (48.8, 2.3), "frm": (48.8, 2.3), "xno": (51.5, -0.1),
    "osp": (42.3, -3.7),          # Old Spanish: Burgos
    "roa-oit": (43.8, 11.2),      # Old Italian: Florence
    # Germanic, historical
    "ang": (52.5, -1.5), "enm": (52.5, -1.0), "en-ear": (51.5, -0.1),
    "goh": (49.5, 9.0), "gmh": (49.5, 10.0), "osx": (52.3, 8.5), "odt": (51.8, 5.5),
    "dum": (51.5, 4.5), "gml": (53.5, 10.0), "ofs": (53.3, 6.5), "non": (61.0, 8.0),
    "got": (45.0, 26.0),          # Gothic: lower Danube (Wulfila's Bible)
    "gmq-osw": (59.3, 18.0), "gmq-oda": (55.7, 12.5), "gmw-msc": (55.9, -3.2),
    # Celtic, historical
    "sga": (53.3, -7.5), "mga": (53.3, -7.5), "owl": (52.3, -3.5), "wlm": (52.3, -3.5),
    "xcg": (45.5, 9.0), "xtg": (47.0, 3.0),  # Cisalpine / Transalpine Gaulish
    # Greek
    "grc": (38.0, 23.7), "gmy": (37.7, 22.8), "grc-koi": (38.0, 23.7), "gkm": (41.0, 29.0),
    # Slavic, historical
    "cu": (41.5, 22.0), "orv": (50.45, 30.5), "zlw-opl": (52.0, 19.0),
    "zlw-ocs": (50.1, 14.4), "zle-ort": (53.9, 27.6), "zlw-osk": (48.7, 19.0),
    # Indo-Iranian, historical
    "sa": (29.0, 77.0), "vsn": (31.0, 74.0), "pra": (25.0, 82.0), "pi": (25.0, 85.0),
    "ae": (37.0, 66.0), "peo": (30.0, 52.9), "pal": (33.0, 53.0), "xcl": (40.0, 44.5),
    # Near East
    "akk": (33.1, 44.1), "sux": (31.3, 45.6), "egy": (26.0, 32.0), "arc": (36.0, 39.0),
    "hbo": (31.8, 35.2), "sem-pro": (33.0, 40.0), "phn": (33.9, 35.5),
    # other families
    "urj-pro": (57.0, 55.0), "urj-fin-pro": (59.0, 28.0), "smi-pro": (64.0, 26.0),
    "trk-pro": (47.0, 100.0), "dra-pro": (17.0, 78.0), "sa-ved": (30.0, 75.0),
    "nah": (19.4, -99.1),  # Nahuatl: Valley of Mexico
}

# Wiktionary codes that aren't ISO 639-3 but name a language Glottolog has under another.
ALIASES = {"sh": "hbs", "no": "nor", "cmn": "cmn", "nds-de": "nds", "nds-nl": "nds"}


def download():
    GEO.mkdir(parents=True, exist_ok=True)
    for name, url in SOURCES.items():
        if not (GEO / name).exists():
            subprocess.run(["curl", "-sSfL", "-A", "EtymonPipeline/0.1", "-o", GEO / name, url],
                           check=True)


def glottolog_points():
    """ISO 639-3 -> (lat, lon) for every Glottolog language with a point."""
    points = {}
    with open(GEO / "glottolog.csv", newline="") as f:
        for row in csv.DictReader(f):
            iso, lat, lon = row["ISO639P3code"], row["Latitude"], row["Longitude"]
            if iso and lat and lon:
                points[iso] = (round(float(lat), 3), round(float(lon), 3))
    return points


def iso_part1():
    """ISO 639-1 (two letters) -> ISO 639-3."""
    with open(GEO / "iso-639-3.tab", newline="") as f:
        return {r["Part1"]: r["Id"] for r in csv.DictReader(f, delimiter="\t") if r["Part1"]}


def macro_members():
    """Macrolanguage (hbs, nor, zho...) -> its first individual member with a point,
    through Glottolog's points; filled in by locate()."""
    return {"hbs": "srp", "nor": "nob", "zho": "cmn", "ara": "arb", "fas": "pes",
            "msa": "zsm", "est": "ekk", "lav": "lvs", "sqi": "als", "aze": "azj",
            "uzb": "uzn", "mon": "khk", "kur": "kmr", "swa": "swh", "yid": "ydd",
            "grn": "gug", "que": "quy", "ori": "ory", "pus": "pbu", "orm": "gaz"}


def locate(languages, etym, families):
    """code -> (lat, lon, source) for every Wiktionary language and variety we can place."""
    points, part1, macro = glottolog_points(), iso_part1(), macro_members()

    def glotto(code):
        iso = ALIASES.get(code) or part1.get(code) or code
        iso = macro.get(iso, iso) if iso not in points else iso
        return points.get(iso)

    found, visiting = {}, set()

    def place(code):
        if code in found:
            return found[code]
        if code in visiting:
            return None
        visiting.add(code)
        result = None
        if code in HOMELANDS:
            result = (*HOMELANDS[code], "homeland")
        elif (p := glotto(code)):
            result = (*p, "glottolog")
        else:
            # a variety of a fuller language, the language it descends from, or its family
            lang, var = languages.get(code, {}), etym.get(code, {})
            ancestors = (lang.get("ancestors") or "").split(",")
            candidates = [var.get("parent"), *ancestors]
            # climb families: gmq-eas -> gmq -> gem, trying each one's proto-language
            family, climbed = lang.get("3"), set()
            while family and family not in climbed:
                climbed.add(family)
                fam = families.get(family, {})
                candidates.append(fam.get("protoLanguage") or f"{family}-pro")
                family = fam.get("3")
            for c in filter(None, candidates):
                if (p := place(c)):
                    result = (p[0], p[1], f"via {c}")
                    break
        visiting.discard(code)
        if result:
            found[code] = result
        return result

    for code in [*languages, *etym, *HOMELANDS]:
        place(code)
    return found


def write(db_path, located):
    db = sqlite3.connect(db_path)
    db.executescript("""
        DROP TABLE IF EXISTS language_geo;
        CREATE TABLE language_geo (code TEXT PRIMARY KEY, lat REAL, lon REAL, source TEXT);
    """)
    db.executemany("INSERT INTO language_geo VALUES (?,?,?,?)",
                   [(c, *v) for c, v in located.items()])
    used, placed = db.execute("""
        SELECT count(*), sum(g.code IS NOT NULL) FROM (SELECT DISTINCT lang FROM term) t
        LEFT JOIN language_geo g ON g.code = t.lang""").fetchone()
    words, words_placed = db.execute("""
        SELECT count(*), sum(g.code IS NOT NULL) FROM term t
        LEFT JOIN language_geo g ON g.code = t.lang""").fetchone()
    db.commit()
    db.close()
    print(f"{db_path.name}: {placed:,}/{used:,} languages placed, "
          f"covering {words_placed / max(words, 1):.1%} of terms")


if __name__ == "__main__":
    download()
    languages = json.load(open(DATA / "languages.json"))
    etym = json.load(open(DATA / "etym_languages.json"))
    families = json.load(open(DATA / "families.json"))
    located = locate(languages, etym, families)
    targets = [Path(p) for p in sys.argv[1:]] or [
        p for p in (DATA / "etymon.sqlite", DATA / "etymon-mobile.sqlite") if p.exists()]
    for path in targets:
        write(path, located)
