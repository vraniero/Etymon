"""Build the etymology graph as SQLite from the slim dumps and Wiktionary language data.

Nodes are (language, word) terms; edges are typed relationships pointing from a
term to its source:

    inherited      Latin pater      -> Proto-Italic *patēr   (native line of descent)
    derived        unspecified "from X"
    borrowed       English coffee   -> Italian caffè          (cross-language transfer)
    learned        learned borrowing from a classical language
    calque         loan translation
    semantic_loan  meaning borrowed onto an existing word
    root           word -> reconstructed root (e.g. PIE *peh₂-)
    component      word -> morpheme/compound part
    cognate        shares an ancestor (undirected)
    doublet        same language, same ancestor, different paths (undirected)

Edges marked inferred=1 come from reading an etymology as a chain ("from X, from Y"):
X -> Y is attributed to X even though it was stated on another entry.

Usage: .venv/bin/python build_graph.py [out.sqlite]
"""
import gzip
import json
import sqlite3
import sys
import unicodedata
from pathlib import Path

from wordfreq import zipf_frequency

DATA = Path(__file__).parent / "data"
MODERN = ("en", "it", "es", "fr", "de")

ANCESTRY = {
    "inh": "inherited", "inh+": "inherited", "inh-lite": "inherited",
    "der": "derived", "der+": "derived", "der-lite": "derived", "uder": "derived",
    "bor": "borrowed", "bor+": "borrowed", "obor": "borrowed", "ubor": "borrowed",
    "unadapted borrowing": "borrowed", "orthographic borrowing": "borrowed",
    "psm": "borrowed", "phono-semantic matching": "borrowed",
    "lbor": "learned", "lbor+": "learned", "learned borrowing": "learned",
    "slbor": "learned", "slbor+": "learned", "semi-learned borrowing": "learned",
    "calque": "calque", "cal": "calque", "clq": "calque",
    "partial calque": "calque", "pcal": "calque",
    "semantic loan": "semantic_loan", "sl": "semantic_loan",
}
COGNATE = {"cog", "cognate"}
DOUBLET = {"doublet", "dbt"}
COMPONENT = {"af", "affix", "compound", "com", "confix", "con", "blend", "surf",
             "prefix", "pre", "suffix", "suf"}

# Wiktionary page names drop vowel-length marks in these languages (pātrem -> patrem).
STRIP_LENGTH_ROOTS = {"la", "ang", "grc"}
LENGTH_MARKS = {"\u0304", "\u0306"}  # combining macron, breve
# Script-level marks that page names omit: Arabic harakat, Hebrew niqqud, Cyrillic stress.
ARABIC_MARKS = {chr(c) for c in range(0x064B, 0x0653)} | {"\u0670"}
HEBREW_MARKS = {chr(c) for c in range(0x0591, 0x05C8)} - {"\u05BE", "\u05C0", "\u05C3", "\u05C6"}
CYRILLIC_STRESS = {"\u0301", "\u0300"}

SCHEMA = """
CREATE TABLE family   (code TEXT PRIMARY KEY, name TEXT, parent TEXT);
CREATE TABLE language (code TEXT PRIMARY KEY, name TEXT, family TEXT,
                       parent TEXT, ancestors TEXT);
CREATE TABLE term     (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, word TEXT NOT NULL,
                       gloss TEXT, etym TEXT, zipf REAL, has_entry INTEGER,
                       UNIQUE (lang, word));
CREATE TABLE edge     (src INTEGER NOT NULL, dst INTEGER NOT NULL, kind TEXT NOT NULL,
                       inferred INTEGER NOT NULL, PRIMARY KEY (src, dst, kind));
CREATE TABLE form     (lang TEXT NOT NULL, form TEXT NOT NULL, lemma INTEGER NOT NULL,
                        PRIMARY KEY (lang, form, lemma));
"""


def load_languages():
    langs = json.load(open(DATA / "languages.json"))
    etym = json.load(open(DATA / "etym_languages.json"))
    fams = json.load(open(DATA / "families.json"))
    language_rows = {}
    for code, v in langs.items():
        language_rows[code] = (code, v.get("1"), v.get("3"), None, v.get("ancestors"))
    for code, v in etym.items():
        # Etymology-only varieties (Late Latin, Vulgar Latin...) hang off a parent language.
        language_rows[code] = (code, v.get("1"), None, v.get("parent"), None)
    family_rows = [(code, v.get("1"), v.get("3")) for code, v in fams.items()]
    return language_rows, family_rows


def base_language(code, language_rows):
    """Follow etymology-only varieties up to a full language (LL. -> la)."""
    seen = set()
    while code in language_rows and language_rows[code][3] and code not in seen:
        seen.add(code)
        code = language_rows[code][3]
    return code


class Graph:
    def __init__(self, language_rows):
        self.language_rows = language_rows
        self.ids = {}
        self.info = {}        # id -> [gloss, etym, has_entry]
        self.edges = {}       # (src, dst, kind) -> inferred
        self.forms = set()
        self._strip_cache = {}

    def strips_length(self, lang):
        if lang not in self._strip_cache:
            self._strip_cache[lang] = base_language(lang, self.language_rows) in STRIP_LENGTH_ROOTS
        return self._strip_cache[lang]

    def clean(self, lang, word):
        word = (word or "").replace("[[", "").replace("]]", "").strip()
        if not word or word in ("-", "?", "*"):
            return None
        word = unicodedata.normalize("NFD", word)
        drop = set()
        if self.strips_length(lang):
            drop |= LENGTH_MARKS
        if any("\u0600" <= c <= "\u06FF" for c in word):
            drop |= ARABIC_MARKS
        if any("\u0590" <= c <= "\u05FF" for c in word):
            drop |= HEBREW_MARKS
        if any("\u0400" <= c <= "\u04FF" for c in word):
            drop |= CYRILLIC_STRESS
        if drop:
            word = "".join(c for c in word if c not in drop)
        return unicodedata.normalize("NFC", word)

    def node(self, lang, word):
        word = self.clean(lang, word)
        if not lang or not word:
            return None
        key = (lang, word)
        if key not in self.ids:
            self.ids[key] = len(self.ids) + 1
            self.info[self.ids[key]] = ["", "", 0]
        return self.ids[key]

    def edge(self, src, dst, kind, inferred):
        if src is None or dst is None or src == dst:
            return
        if kind in ("cognate", "doublet") and src > dst:
            src, dst = dst, src  # undirected: store once
        key = (src, dst, kind)
        # a direct statement beats an inferred one
        self.edges[key] = min(self.edges.get(key, 1), inferred)

    def add_entry(self, e):
        lang, word = e["l"], e["w"]
        head = self.node(lang, word)
        if head is None:
            return
        info = self.info[head]
        info[2] = 1
        if not info[0] and e["g"]:
            info[0] = e["g"]
        if not info[1] and e["e"]:
            info[1] = e["e"]
        if e.get("f"):
            lemma = self.node(lang, e["f"])
            if lemma and lemma != head:
                self.forms.add((lang, self.clean(lang, word), lemma))

        prev = head
        for t in e["t"]:
            name, a = t["n"], t["a"]
            if name in ANCESTRY:
                src = self.node(a.get("2"), a.get("3"))
                if src is None or src == prev:
                    continue
                self.edge(prev, src, ANCESTRY[name], int(prev != head))
                prev = src
            elif name == "root":
                for k in range(3, 8):
                    self.edge(head, self.node(a.get("2"), a.get(str(k))), "root", 0)
            elif name in COGNATE:
                self.edge(head, self.node(a.get("1"), a.get("2")), "cognate", 0)
            elif name in DOUBLET:
                for k in range(2, 6):
                    self.edge(head, self.node(lang, a.get(str(k))), "doublet", 0)
            elif name in COMPONENT:
                for k in range(2, 8):
                    part = a.get(str(k))
                    if not part:
                        continue
                    part_lang = lang
                    # af/compound parts may be language-prefixed: "la:pater"
                    if ":" in part and part.split(":", 1)[0] in self.language_rows:
                        part_lang, part = part.split(":", 1)
                    self.edge(head, self.node(part_lang, part), "component", 0)


def read_slim(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        try:
            for line in f:
                yield json.loads(line)
        except (EOFError, json.JSONDecodeError):
            print(f"  warning: {path.name} is truncated, using what was read", flush=True)


def main(out_path):
    language_rows, family_rows = load_languages()
    graph = Graph(language_rows)

    files = sorted(DATA.glob("*.slim.jsonl.gz"))
    if not files:
        sys.exit("no data/*.slim.jsonl.gz files; run fetch.py first")
    for path in files:
        n = 0
        for entry in read_slim(path):
            graph.add_entry(entry)
            n += 1
        print(f"{path.name}: {n:,} entries", flush=True)

    out_path = Path(out_path)
    out_path.unlink(missing_ok=True)
    db = sqlite3.connect(out_path)
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO family VALUES (?,?,?)", family_rows)
    db.executemany("INSERT INTO language VALUES (?,?,?,?,?)", language_rows.values())

    def term_rows():
        for (lang, word), tid in graph.ids.items():
            gloss, etym, has_entry = graph.info[tid]
            zipf = zipf_frequency(word, lang) if lang in MODERN else None
            yield tid, lang, word, gloss or None, etym or None, zipf or None, has_entry

    db.executemany("INSERT INTO term VALUES (?,?,?,?,?,?,?)", term_rows())
    db.executemany("INSERT INTO edge VALUES (?,?,?,?)",
                   ((s, d, k, i) for (s, d, k), i in graph.edges.items()))
    db.executemany("INSERT INTO form VALUES (?,?,?)", graph.forms)
    db.executescript("""
        CREATE INDEX edge_dst ON edge(dst);
        CREATE INDEX term_word ON term(word COLLATE NOCASE);
    """)
    db.commit()
    for table in ("term", "edge", "form", "language"):
        print(f"{table}: {db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]:,}")
    db.close()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DATA / "etymon.sqlite")
