"""A word made of several words goes back through each of them: every ancestor, not one line."""
import sqlite3

import pytest
from fastapi.testclient import TestClient

import app as api
from connect import ancestry, lineage

pytestmark = pytest.mark.skipif(not api.DB_PATH.exists(), reason="no etymon.sqlite")
client = TestClient(api.app)


def ancestors(body, entry):
    """{word: [words it is an ancestor of]} from a /word entry."""
    nodes = body["nodes"]
    word = lambda i: nodes[str(i)]["word"]
    out = {}
    for s in entry["lineage"]:
        out.setdefault(word(s["node"]), []).append(word(s["from"]))
    return out


def test_compound_reaches_every_part():
    body = client.get("/word", params={"text": "Handschuh", "lang": "de"}).json()
    up = ancestors(body, body["entries"][0])
    assert "Handschuh" in up["Hand"] and "Handschuh" in up["Schuh"]
    assert "*handu" in up and "*skōh" in up  # both lines go on to Proto-West Germanic


def test_parts_of_an_older_compound():
    """football < Middle English fotbal, itself fot + bal: both ancestors are kept."""
    body = client.get("/word", params={"text": "football", "lang": "en"}).json()
    up = ancestors(body, body["entries"][0])
    assert "fotbal" in up["fot"] and "fotbal" in up["bal"]
    assert any(w.startswith("*fōt") for w in up) and any(w.startswith("*ballō") for w in up)


def test_every_step_hangs_from_a_node_already_listed():
    body = client.get("/word", params={"text": "ferrovia", "lang": "it"}).json()
    entry = body["entries"][0]
    known = {entry["term"]}
    for s in entry["lineage"]:
        assert s["from"] in known
        known.add(s["node"])
        assert str(s["node"]) in body["nodes"]


def test_main_line_comes_first():
    db = sqlite3.connect(api.DB_PATH)
    term = db.execute("SELECT id FROM term WHERE lang='en' AND word='football'").fetchone()[0]
    tree, line = ancestry(db, term), lineage(db, term)
    child = term
    for (n, k, c), (m, j) in zip(tree, [x for x in line if x[1] != "root"]):
        assert (n, k, c) == (m, j, child)
        child = n


def test_scene_deeper_is_a_tree():
    """Above a meeting point, its parts too: Eisenbahn (calqued as ferrovia) is Eisen + Bahn."""
    r = client.post("/scene", json={"words": [{"text": "ferrovia", "lang": "it"},
                                              {"text": "Eisenbahn", "lang": "de"}]})
    body = r.json()
    words = {body["nodes"][str(s["node"])]["word"]
             for c in body["connections"] for s in c["deeper"]}
    for c in body["connections"]:
        known = {c["meet"]}
        for s in c["deeper"]:
            assert s["from"] in known
            known.add(s["node"])
    assert {"Eisen", "Bahn"} <= words or not body["connections"]
