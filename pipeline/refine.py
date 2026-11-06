"""Post-build passes over the graph that join what citation habits split apart.

1. Spelling variants of reconstructions. Entries cite reconstructions with accents, tones
   and syllabic marks their page names leave out, or spell them a little differently:
   Latin septimus cites *septmós, the page is *septm̥mós; Proto-Slavic citations carry
   tones (*žìto, page *žito). The cited form becomes a dead end (no entry, no sources)
   and the line of descent stops there. Where such a dead end matches exactly one entry
   of the same language once those marks are set aside, its links move to that entry.

2. Lexical affixes (and the "combining form of W" glosses that link some to W). The search never climbs into an affix ("-ism", "re-"): thousands of
   words share each, which says nothing. But some are combining forms of real words,
   used by a few hundred: Italian bio- (from Greek βίος), auto- (αὐτός), -grafia. Closed,
   they cut every word built on them from its ancestry (autobiografia never reached
   βίος). Affixes that are combining forms of one real word (see open_affixes) are
   listed in `open_affix`; connect.py lets the search pass through them.

Run by build_graph.py; also on its own over a built database:
    .venv/bin/python refine.py [data/etymon.sqlite]
"""
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict, deque
from pathlib import Path

# Prosodic marks on vowels (and syllabic resonants) that page names drop: grave, acute,
# circumflex, tilde, macron, breve, double grave, inverted breve. Letters that carry a
# mark as part of them stay distinct: ḱ, ś (consonant + acute), ǫ (ogonek), ě, š (caron).
PROSODIC = {"̀", "́", "̂", "̃", "̄", "̆", "̏", "̑"}
SYLLABIC = {"̥", "̩"}  # ring / vertical line below: m̥, r̥, l̩
VOWELS = set("aeiouyæɛɔəɨʉøœɑɒıǝъьAEIOUYÆƐƆƏ")
RESONANTS = set("rlmnRLMN")

# A combining form used by more words than this is a grammatical affix in all but name
# (Italian -mente 3.6k, English un- 14k, -ness 11k); below it, lexical ones (bio- 215
# in Italian, 1.4k in English; -grafia 121).
MAX_AFFIX_USES = 1500
AFFIX_HOPS = 4
ANCESTRY = ("inherited", "borrowed", "learned", "calque", "semantic_loan", "derived",
            "component", "root")
# what an affix comes from: not its own parts, nor a root it is filed under
LINEAGE = ("inherited", "borrowed", "learned", "calque", "semantic_loan", "derived")


def is_affix(word):
    if word.startswith("*"):
        return word[1:].startswith("-")
    return word.startswith("-") or word.endswith("-")


def variant_key(word):
    """*septm̥mós and *septmós -> "septmos"; *žìto and *žito -> "žito"; *gʰreH₁- and
    *gʰreh₁- -> "gʰreh₁-". Hyphens stay: *-slo (suffix) is not *slo."""
    s = unicodedata.normalize("NFD", word.removeprefix("*"))
    out, cluster = [], []

    def flush():
        if not cluster:
            return
        base, marks = cluster[0], cluster[1:]
        if base in VOWELS or (base in RESONANTS and SYLLABIC & set(marks)):
            marks = [m for m in marks if m not in PROSODIC and m not in SYLLABIC]
        out.append(base + "".join(marks))
        cluster.clear()

    for c in s:
        if unicodedata.combining(c) and cluster:
            cluster.append(c)
        else:
            flush()
            cluster.append(c)
    flush()
    s = unicodedata.normalize("NFC", "".join(out)).replace("(", "").replace(")", "").lower()
    return re.sub(r"(.)\1+", r"\1", s)  # *septm̥mós has the m twice once the ring goes


def merge_variants(db):
    """Moves the links of dead-end reconstructions onto the entry they spell. Returns the
    number of dead ends merged."""
    entries = defaultdict(list)
    for tid, lang, word in db.execute(
            "SELECT id, lang, word FROM term WHERE has_entry=1 AND word LIKE '*%'"):
        entries[(lang, variant_key(word))].append(tid)
    kinds = ",".join("?" * len(ANCESTRY))
    dead = db.execute(
        f"SELECT t.id, t.lang, t.word FROM term t WHERE t.has_entry=0 AND t.word LIKE '*%' "
        f"AND EXISTS (SELECT 1 FROM edge e WHERE e.dst=t.id) "
        f"AND NOT EXISTS (SELECT 1 FROM edge e WHERE e.src=t.id AND e.kind IN ({kinds}))",
        ANCESTRY).fetchall()
    merged = 0
    for tid, lang, word in dead:
        match = entries.get((lang, variant_key(word)))
        if not match or len(match) != 1:
            continue  # unknown, or ambiguous: leave it
        target = match[0]
        # move both ends; a link already present on the entry wins (keep the stated one)
        db.execute("INSERT OR IGNORE INTO edge SELECT src, ?, kind, inferred FROM edge "
                   "WHERE dst=? AND src<>?", (target, tid, target))
        db.execute("INSERT OR IGNORE INTO edge SELECT ?, dst, kind, inferred FROM edge "
                   "WHERE src=? AND dst<>?", (target, tid, target))
        db.execute("DELETE FROM edge WHERE src=? OR dst=?", (tid, tid))
        merged += 1
    return merged


def open_affixes(db):
    """Fills `open_affix` with the lexical affixes: combining forms of a real word, as
    Italian bio- is of Greek βίος. An affix is open when
      - at most MAX_AFFIX_USES words are built on it,
      - its line of stated links (through other affixes: Italian bio- -> Greek βιο- ->
        βίος) reaches exactly one full word, of at least 4 letters (not a preposition:
        ab, ex, *za),
      - and that word means what the affix means: their glosses share a stem (tele-
        "distant" / τῆλε "far off"); an affix glossed only by its spelling (Italian
        micro-: "micro-") is read through the English affix of that spelling ("small").
    Reconstructed prefixes (*missa-, *prai-) are affixes here too, not full words.
    The last two keep out grammatical affixes ("-ion: an action or process"), and pages
    that mix homonyms (English bi- "two" listed as from βίος "life").
    Returns how many."""
    db.execute("DROP TABLE IF EXISTS open_affix")
    db.execute("CREATE TABLE open_affix (id INTEGER PRIMARY KEY)")
    uses = dict(db.execute(
        "SELECT dst, count(*) FROM edge WHERE kind='component' GROUP BY dst"))
    terms = {tid: (w, g) for tid, w, g in db.execute("SELECT id, word, gloss FROM term")}
    # English glosses of affixes, for those glossed only by their own spelling elsewhere
    english = {w: g for w, g in db.execute(
        "SELECT word, gloss FROM term WHERE lang='en' AND has_entry=1 AND gloss IS NOT NULL "
        "AND (word LIKE '-%' OR word LIKE '%-')")}
    up = defaultdict(list)
    kinds = ",".join("?" * len(LINEAGE))
    # stated links only: chains read off other entries' prose wander (-λογία -> *gʷelH-)
    for src, dst in db.execute(f"SELECT src, dst FROM edge WHERE inferred=0 AND kind IN ({kinds})",
                               LINEAGE):
        if is_affix(terms.get(src, ("", None))[0]):
            up[src].append(dst)

    def lexical(start):
        found = {}
        seen, queue = {start}, deque([(start, 0)])
        while queue:
            node, hops = queue.popleft()
            for dst in up.get(node, ()):
                if dst in seen or dst not in terms:
                    continue
                seen.add(dst)
                word, gloss = terms[dst]
                if not is_affix(word) and not affix_like(word, gloss):
                    found[fold(word)] = gloss
                elif hops + 1 < AFFIX_HOPS:
                    queue.append((dst, hops + 1))
        if len(found) != 1:
            return False
        (word, gloss), = found.items()
        if len(word.strip("*")) < 4:
            return False  # a preposition (ab, ex, *za), not a word with a meaning to carry
        own_word, own_gloss = terms[start]
        if not stems(own_gloss, own_word, grammar=True):
            # glossed by its own spelling (Italian micro-: "micro-"): read the English
            # affix of that spelling (micro-: "small"); with none, no way to tell
            own_gloss = english.get(own_word)
        meant = stems(own_gloss, own_word)
        return bool(meant & stems(gloss))  # only grammar ("an action or process"): closed

    opened = [tid for tid in up if uses.get(tid, 0) <= MAX_AFFIX_USES and lexical(tid)]
    db.executemany("INSERT INTO open_affix VALUES (?)", ((t,) for t in opened))
    return len(opened)


AFFIX_GLOSS = re.compile(r"(?:^|[\s,;(“\"])-\w|\w-(?:[\s,;)”\"]|$)|^\s*(?:forms?|forming|used to form|"
                         r"prefix|suffix)\b", re.I)


def affix_like(word, gloss):
    """Reconstructed prefixes are cited like stems (*missa-, *wre-, *prai-): told apart
    by glosses that are about affixes ("mis-, wrongly"; "forms verbs…") or say nothing."""
    if not word.endswith("-"):
        return False
    return not stems(gloss, word, grammar=True) or bool(AFFIX_GLOSS.search(gloss or ""))


BASIC_STOPWORDS = set(
    "a an the of to in on or and with for by as from at into used form forms forming formed "
    "word words term terms that which is are be its it this than other relating related "
    "pertaining having denoting indicating".split())
GLOSS_STOPWORDS = BASIC_STOPWORDS | {
    # the grammar of affix glosses: "attached to a verb to form a noun denoting the action"
    "noun", "nouns", "verb", "verbs", "adjective", "adjectives", "adverb", "adverbs",
    "attached", "prefix", "prefixed", "suffix", "suffixed", "added", "indicates",
    "indicate", "denotes", "denote", "meaning", "means", "action", "actions", "result",
    "process", "state", "quality", "root", "base", "creates", "makes", "expresses"}


def stems(gloss, own="", grammar=False):
    """Content words of a gloss, cut to four letters: "writing" and "to write" share writ.
    An affix's own spelling in its gloss (Italian micro-: "micro-") says nothing; nor do
    the grammar words of affix glosses, unless `grammar` (to tell them from nothing)."""
    own = fold(own).strip("*-")
    stop = BASIC_STOPWORDS if grammar else GLOSS_STOPWORDS
    return {w[:4] for w in re.findall(r"[a-z]+", fold(gloss or ""))
            if len(w) > 2 and w not in stop and w != own}


def fold(word):
    return "".join(c for c in unicodedata.normalize("NFD", word)
                   if not unicodedata.combining(c)).lower()


COMBINING_FORM = re.compile(r"^(?:\([^)]*\)\s*)?combining form of (\S+?)[,;]?\s+\(", re.I)


def link_combining_forms(db):
    """Affixes glossed as "combining form of W (…)" — Greek βιο-, "combining form of βίος
    (bíos, “life”)" — come from W, which their entries often state nowhere else. Only
    with W cited in its own script and explained in brackets: English bio-, "combining
    form of life", is not from the English word. Returns links added."""
    added = 0
    for tid, lang, gloss in db.execute(
            "SELECT id, lang, gloss FROM term WHERE has_entry=1 AND gloss LIKE '%ombining form of %' "
            "AND (word LIKE '-%' OR word LIKE '%-')").fetchall():
        m = COMBINING_FORM.match(gloss)
        row = m and db.execute("SELECT id FROM term WHERE lang=? AND word=?",
                               (lang, m.group(1))).fetchone()
        if row and row[0] != tid:
            added += db.execute("INSERT OR IGNORE INTO edge VALUES (?, ?, 'derived', 0)",
                                (tid, row[0])).rowcount
    return added


def refine(db):
    merged = merge_variants(db)
    linked = link_combining_forms(db)
    opened = open_affixes(db)
    db.commit()
    print(f"refine: {merged:,} reconstruction spellings merged, {linked:,} combining forms "
          f"linked, {opened:,} affixes opened", flush=True)
    return merged, linked, opened


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "data" / "etymon.sqlite"
    refine(sqlite3.connect(path))
