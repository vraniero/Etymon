"""API checks against the built graph (skipped if the database is missing)."""
import pytest
from fastapi.testclient import TestClient

import app as api

pytestmark = pytest.mark.skipif(not api.DB_PATH.exists(), reason="no etymon.sqlite")
client = TestClient(api.app)


def meet_word(resp, a, b):
    nodes = resp["nodes"]
    for c in resp["connections"]:
        if {c["a"], c["b"]} == {a, b}:
            n = nodes[str(c["meet"])]
            return n["lang"], n["word"]
    return None


def test_scene_connects_through_latin():
    r = client.post("/scene", json={"words": [{"text": "padre", "lang": "it"},
                                              {"text": "paternalistic", "lang": "en"}]})
    assert r.status_code == 200
    body = r.json()
    assert meet_word(body, 0, 1) == ("la", "pater")
    conn = body["connections"][0]
    deeper = [body["nodes"][str(s["node"])]["word"] for s in conn["deeper"]]
    assert "*ph₂tḗr" in deeper


def test_language_detected_and_ocr_noise_stripped():
    r = client.post("/scene", json={"words": [{"text": "NOCHE,"}, {"text": "Nacht"}]}).json()
    assert [w["lang"] for w in r["words"]] == ["es", "de"]
    assert meet_word(r, 0, 1) == ("ine-pro", "*nókʷts")


def test_inflected_form_resolves_to_lemma():
    r = client.get("/word", params={"text": "padri", "lang": "it"}).json()
    words = {n["word"] for n in r["nodes"].values()}
    assert {"padre", "pater"} <= words


def test_unknown_word():
    assert client.get("/word", params={"text": "xqzzv", "lang": "en"}).status_code == 404
    r = client.post("/scene", json={"words": [{"text": "xqzzv"}, {"text": "padre"}]}).json()
    assert r["words"][0]["terms"] == [] and r["connections"] == []


def test_scene_language_hint_with_fallback():
    r = client.post("/scene", json={"lang": "it", "words": [
        {"text": "FARMACIA"}, {"text": "pharmacy"}]}).json()
    assert [w["lang"] for w in r["words"]] == ["it", "en"]
    assert r["connections"]


def test_scene_hint_yields_to_much_more_common_language():
    # "night" exists in Italian (nightclub) but on an Italian sign it is English
    r = client.post("/scene", json={"lang": "it", "words": [
        {"text": "notte"}, {"text": "night"}, {"text": "Padre"}]}).json()
    assert [w["lang"] for w in r["words"]] == ["it", "en", "it"]


def test_semantic_links_between_translations():
    # aperta and open share no ancestry (Latin apertus vs Germanic *upanaz) but mean the same
    r = client.post("/scene", json={"lang": "it", "words": [
        {"text": "Aperta"}, {"text": "Open"}, {"text": "notte"}, {"text": "night"}]}).json()
    links = {(l["a"], l["b"]): l["meaning"] for l in r["semantic"]}
    assert links.get((0, 1)) == "open"
    assert links.get((2, 3)) == "night"
    # notte and night are also related by descent (PIE *nókʷts)
    assert any({c["a"], c["b"]} == {2, 3} for c in r["connections"])
    assert not any({c["a"], c["b"]} == {0, 1} for c in r["connections"])
