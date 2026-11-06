"""Checks of the graph-building passes on small hand-made graphs (no dumps needed).

Run: .venv/bin/python -m pytest test_refine.py
"""
import sqlite3

from build_graph import SCHEMA, strip_modifiers
from connect import climb, lineage
from refine import link_combining_forms, merge_variants, open_affixes, variant_key


def test_modifiers_are_not_part_of_the_word():
    assert strip_modifiers("-tio<alt:-tionem>") == "-tio"
    assert strip_modifiers("𐬭𐬀𐬙𐬎<t:time period>") == "𐬭𐬀𐬙𐬎"
    assert strip_modifiers("*septmas<ety:inh<ine-pro:*septm̥mós>>") == "*septmas"
    assert strip_modifiers("pater") == "pater"


def test_variant_keys_drop_prosody_only():
    assert variant_key("*septmós") == variant_key("*septm̥mós")
    assert variant_key("*žìto") == variant_key("*žito")
    assert variant_key("*gʰreH₁-") == variant_key("*gʰreh₁-")
    assert variant_key("*bar(ī)") == variant_key("*barī")
    # distinct letters and affixes stay apart
    assert variant_key("*ǫgrъ") != variant_key("*ogrъ")
    assert variant_key("*grьmęti") != variant_key("*grьměti")
    assert variant_key("*derḱ-") != variant_key("*derk-")
    assert variant_key("*-slo") != variant_key("*slo")


def graph(terms, edges):
    """terms: {id: (lang, word, has_entry[, gloss])}; edges: [(src, dst, kind)]."""
    db = sqlite3.connect(":memory:")
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO term (id, lang, word, has_entry, gloss) VALUES (?,?,?,?,?)",
                   ((i, t[0], t[1], t[2], t[3] if len(t) > 3 else None) for i, t in terms.items()))
    db.executemany("INSERT INTO edge VALUES (?,?,?,0)", edges)
    return db


def test_dead_end_spelling_joins_its_entry():
    """Latin septimus cites *septmós; the page is *septm̥mós, which goes on to *septḿ̥."""
    db = graph({1: ("la", "septimus", 1), 2: ("ine-pro", "*septmós", 0),
                3: ("ine-pro", "*septm̥mós", 1), 4: ("ine-pro", "*septḿ̥", 1),
                5: ("en", "seven", 1)},
               [(1, 2, "inherited"), (3, 4, "component"), (5, 4, "inherited")])
    assert merge_variants(db) == 1
    up = climb(db, [1])
    assert 4 in up  # septimus now reaches *septḿ̥, where seven meets it
    assert not db.execute("SELECT 1 FROM edge WHERE src=2 OR dst=2").fetchone()


def test_ambiguous_or_living_terms_are_left_alone():
    db = graph({1: ("la", "a", 1), 2: ("ine-pro", "*bʰer-", 0),
                3: ("ine-pro", "*bʰér-", 1), 4: ("ine-pro", "*bʰēr-", 1),
                5: ("la", "b", 1), 6: ("ine-pro", "*wódr̥", 0), 7: ("ine-pro", "*x", 1)},
               [(1, 2, "inherited"), (5, 6, "inherited"), (6, 7, "derived")])
    # *bʰer- matches two entries; *wódr̥ has sources of its own: neither is merged
    assert merge_variants(db) == 0


def test_lexical_affixes_open_grammatical_ones_stay_closed():
    """autobiografia -> biografia -> bio- -> βίος, and biologia -> bio-: they meet."""
    terms = {1: ("it", "autobiografia", 1, "autobiography"), 2: ("it", "biografia", 1, "biography"),
             3: ("it", "bio-", 1, "bio- (life)"), 4: ("grc", "βίος", 1, "life"),
             5: ("it", "biologia", 1, "biology"),
             # grammatical: its gloss is only grammar
             6: ("it", "-zione", 1, "used to form nouns relating to the action"),
             7: ("la", "-tio", 1, "forms nouns"), 8: ("it", "nazione", 1, "nation"),
             # too common, even if from a word
             9: ("it", "-mente", 1, "-ly"), 10: ("la", "mens", 1, "mind"),
             # a page mixing homonyms: bi- "two" listed as from βίος "life"
             11: ("en", "bi-", 1, "Two in number."),
             # glossed by its spelling: read through English anti- "against", not "before"
             12: ("it", "anti-", 1, "anti-"), 13: ("la", "ante", 1, "before"),
             14: ("en", "anti-", 1, "against, opposed to"),
             15: ("it", "micro-", 1, "micro-"), 16: ("grc", "μικρός", 1, "little, small"),
             17: ("en", "micro-", 1, "small; microscopic"),
             # a reconstructed prefix is not a word
             18: ("en", "mis-", 1, "Bad or wrong"), 19: ("gem-pro", "*missa-", 1, "mis-, wrongly"),
             # a preposition is not a word with a meaning to carry
             20: ("es", "ex-", 1, "out"), 21: ("la", "ex", 1, "out of")}
    edges = [(1, 2, "component"), (2, 3, "component"), (3, 4, "derived"), (5, 3, "component"),
             (8, 6, "component"), (6, 7, "learned"), (9, 10, "inherited"), (11, 4, "derived"),
             (12, 13, "derived"), (15, 16, "derived"), (18, 19, "inherited"), (20, 21, "derived")]
    terms.update({100 + k: ("it", f"parola{k}mente", 1) for k in range(1600)})
    edges += [(100 + k, 9, "component") for k in range(1600)]
    db = graph(terms, edges)
    open_affixes(db)
    assert {i for (i,) in db.execute("SELECT id FROM open_affix")} == {3, 15}
    a, b = climb(db, [1]), climb(db, [5])
    assert 3 in a and 4 in a and 3 in b
    assert 6 not in climb(db, [8])
    assert 10 not in climb(db, [100])
    assert [n for n, _ in lineage(db, 2)] == [3, 4]


def test_combining_form_glosses_link_to_their_word():
    db = graph({1: ("grc", "βιο-", 1, "combining form of βίος (bíos, “life”)"),
                2: ("grc", "βίος", 1, "life"),
                3: ("en", "bio-", 1, "Combining form of life."), 4: ("en", "life", 1, "life")}, [])
    assert link_combining_forms(db) == 1
    assert db.execute("SELECT src, dst, kind FROM edge").fetchall() == [(1, 2, "derived")]
