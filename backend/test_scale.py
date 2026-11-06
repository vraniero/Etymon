"""Scenes of hundreds of words: accepted, and answered in reasonable time."""
import time

from fastapi.testclient import TestClient

from app import MAX_WORDS, app

client = TestClient(app)
WORDS = ("padre madre notte giorno acqua fuoco terra cielo mare sole luna stella casa porta "
         "strada città libro scuola amico tempo").split()


def test_accepts_hundreds_of_words():
    words = [{"text": f"{w}"} for w in WORDS] * 10  # 200, duplicates folded by the backend
    words += [{"text": f"xq{i}"} for i in range(180)]  # unknown words cost little
    assert len(words) <= MAX_WORDS
    started = time.perf_counter()
    r = client.post("/scene", json={"words": words, "lang": "it"})
    assert r.status_code == 200
    assert time.perf_counter() - started < 5
    assert len(r.json()["words"]) == len(WORDS) + 180


def test_rejects_more_than_the_maximum():
    r = client.post("/scene", json={"words": [{"text": f"w{i}"} for i in range(MAX_WORDS + 1)]})
    assert r.status_code == 422
