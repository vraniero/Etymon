"""The word games' puzzles hold up against the graph (skipped without the database)."""
import pytest
from fastapi.testclient import TestClient

import app as api

pytestmark = pytest.mark.skipif(not api.DB_PATH.exists(), reason="no etymon.sqlite")
client = TestClient(api.app)


def scene_meet(a, b):
    r = client.post("/scene", json={"words": [a, b]}).json()
    return r["connections"][0]["meet"] if r["connections"] else None


@pytest.mark.parametrize("lang", ["it", "de"])
def test_impostor_three_share_a_root_and_one_does_not(lang):
    r = client.get("/games/impostor", params={"lang": lang, "seed": 1})
    assert r.status_code == 200
    p = r.json()
    assert len(p["words"]) == 4 and all(w["lang"] == lang for w in p["words"])
    family = [w for i, w in enumerate(p["words"]) if i != p["impostor"]]
    odd = p["words"][p["impostor"]]
    for i, w in enumerate(p["words"]):
        if i != p["impostor"]:
            assert p["paths"][i][-1] == p["root"]
    assert scene_meet(family[0], family[1]) is not None
    assert all(scene_meet(odd, w) is None for w in family)


def test_root_and_check():
    r = client.get("/games/root", params={"lang": "es", "seed": 2})
    assert r.status_code == 200
    root = r.json()
    assert root["total"] >= 8 and root["examples"]
    words = [{"text": root["examples"][0], "lang": "es"}, {"text": "qwzxv"}]
    found = client.post("/games/check", json={"root": root["root"]["id"], "words": words}).json()
    assert [f["text"] for f in found["found"]] == [root["examples"][0]]
    assert found["found"][0]["path"][-1] == root["root"]["id"]
    assert found["unknown"] == ["qwzxv"]


def test_check_pater():
    pater = client.post("/scene", json={"words": [{"text": "padre", "lang": "it"},
                                                  {"text": "paternal", "lang": "en"}]}).json()
    root = pater["connections"][0]["meet"]  # Latin pater
    r = client.post("/games/check", json={"root": root, "words": [
        {"text": "padre", "lang": "it"}, {"text": "patrimony", "lang": "en"},
        {"text": "table", "lang": "en"}]}).json()
    assert [f["text"] for f in r["found"]] == ["padre", "patrimony"]


def test_birthplace_travels():
    r = client.get("/games/birthplace", params={"lang": "en", "seed": 3})
    assert r.status_code == 200
    b = r.json()
    born = b["nodes"][str(b["born"])]
    assert born["lat"] is not None and not born["reconstructed"]
    assert b["journey"][0] != b["born"] and b["journey"][-1] == b["born"]
    assert b["km"] >= 400
