"""Root Chain: the app's move must be one the app itself accepts (skipped without the database)."""
import pytest
from fastapi.testclient import TestClient

import app as api

pytestmark = pytest.mark.skipif(not api.DB_PATH.exists(), reason="no etymon.sqlite")
client = TestClient(api.app)


def scene_meet(a, b):
    r = client.post("/scene", json={"words": [a, b]}).json()
    return r["connections"][0]["meet"] if r["connections"] else None


@pytest.mark.parametrize("level", ["easy", "normal", "hard"])
def test_reply_meets_the_last_word(level):
    last = {"text": "father", "lang": "en"}
    r = client.post("/chain/reply", json={"word": last, "used": ["father"], "level": level,
                                          "seed": 3})
    assert r.status_code == 200
    move = r.json()
    assert move["text"].lower() != "father"
    assert scene_meet(last, {"text": move["text"], "lang": move["lang"]}) == move["meet"]


def test_reply_avoids_used_words_and_the_last_root():
    last = {"text": "padre", "lang": "it"}
    first = client.post("/chain/reply", json={"word": last, "seed": 1}).json()
    again = client.post("/chain/reply", json={
        "word": last, "used": [first["text"]], "avoid_root": first["meet"], "seed": 1}).json()
    assert again["text"] != first["text"]
    assert again["meet"] != first["meet"]


def test_easy_keeps_to_english_and_the_word_s_language():
    r = client.post("/chain/reply", json={"word": {"text": "notte", "lang": "it"},
                                          "level": "easy", "seed": 2}).json()
    assert r["lang"] in {"it", "en"}


def test_unknown_word():
    r = client.post("/chain/reply", json={"word": {"text": "qwzxv", "lang": "en"}})
    assert r.status_code == 404


@pytest.mark.parametrize("lang", ["it", "de", "pl"])
def test_a_game_in_one_language(lang):
    start = client.get("/chain/start", params={"lang": lang, "seed": 4})
    assert start.status_code == 200
    word = start.json()
    assert word["lang"] == lang
    move = client.post("/chain/reply", json={"word": word, "used": [word["text"]],
                                             "level": "hard", "lang": lang, "seed": 4})
    assert move.status_code == 200
    assert move.json()["lang"] == lang
