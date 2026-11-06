"""API checks against the built graph (skipped if the database is missing)."""
import sqlite3

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


def test_nodes_are_placed_on_the_map():
    """Each node carries where its language was spoken: Latin in Rome, PIE on the steppe."""
    r = client.post("/scene", json={"words": [{"text": "padre", "lang": "it"},
                                              {"text": "father", "lang": "en"}]}).json()
    if not api.has_table(sqlite3.connect(api.DB_PATH), "language_geo"):
        pytest.skip("run pipeline/geo.py")
    by_lang = {n["lang"]: (n["lat"], n["lon"]) for n in r["nodes"].values()}
    assert by_lang["la"] == (41.9, 12.5)
    assert by_lang["ine-pro"] == (48.0, 40.0)
    lat, lon = by_lang["en"]
    assert 50 < lat < 56 and -6 < lon < 2  # England


def test_relation_words_are_not_words():
    """"Borrowed from Latin rhombus, borrowed from Ancient Greek..." once made a Latin
    word "borrowed"; relation words never become nodes."""
    r = client.post("/scene", json={"words": [{"text": "coach", "lang": "en"},
                                              {"text": "rhombus", "lang": "en"},
                                              {"text": "rombo", "lang": "it"}]}).json()
    words = {n["word"] for n in r["nodes"].values()}
    assert not words & {"borrowed", "inherited", "derived", "learned"}


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


def test_hint_keeps_homographs_from_other_languages():
    # tej is milk in Hungarian and a much more common word in Polish ("this")
    r = client.post("/scene", json={"lang": "hu", "words": [
        {"text": "víz"}, {"text": "tej"}]}).json()
    assert [w["lang"] for w in r["words"]] == ["hu", "hu"]


def test_cyrillic_scene_links_to_english():
    r = client.post("/scene", json={"lang": "ru", "words": [
        {"text": "Вода"}, {"text": "молоко"}, {"text": "water"}, {"text": "milk"}]}).json()
    assert [w["lang"] for w in r["words"]] == ["ru", "ru", "en", "en"]
    assert meet_word(r, 0, 2) == ("ine-pro", "*wédōr")
    links = {(l["a"], l["b"]): l["meaning"] for l in r["semantic"]}
    assert links.get((1, 3)) == "milk"


def test_central_european_scenes():
    r = client.post("/scene", json={"words": [{"text": "apă", "lang": "ro"},
                                              {"text": "acqua", "lang": "it"}]}).json()
    assert meet_word(r, 0, 1) == ("la", "aqua")
    r = client.post("/scene", json={"words": [{"text": "víz", "lang": "hu"},
                                              {"text": "vesi", "lang": "et"}]}).json()
    assert meet_word(r, 0, 1) == ("urj-pro", "*wete")
    # Serbo-Croatian descendants are listed with tone marks (vòda); they reach the entry
    r = client.get("/word", params={"text": "voda", "lang": "sh"}).json()
    assert any(n["lang"] == "sla-pro" for n in r["nodes"].values())


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


def test_no_false_link_through_related_pie_roots():
    # PIE entries cite other roots as loosely related; that must not connect
    # paternalistic (*peh₂-) to open (*upo)
    r = client.post("/scene", json={"words": [{"text": "paternalistic", "lang": "en"},
                                              {"text": "open", "lang": "en"}]}).json()
    assert r["connections"] == []


def test_neighbors_expand_a_node():
    scene = client.post("/scene", json={"words": [{"text": "padre", "lang": "it"},
                                                  {"text": "paternalistic", "lang": "en"}]}).json()
    pater = scene["connections"][0]["meet"]
    r = client.get("/neighbors", params={"id": pater}).json()
    words = {(n["lang"], n["word"]) for n in r["nodes"].values()}
    kids = {(r["nodes"][str(c["node"])]["lang"], r["nodes"][str(c["node"])]["word"]) for c in r["children"]}
    # direct descendants only (padre comes via Old Italian patre): modern ones listed first
    assert ("de", "Pater") in kids and ("la", "paternus") in kids
    assert kids and list(kids)  # non-empty
    first = r["nodes"][str(r["children"][0]["node"])]["lang"]
    assert first in ("en", "it", "es", "fr", "de")
    assert any(lang == "itc-pro" for lang, _ in words), "parent: Proto-Italic *patēr"
    assert r["total_children"] >= len(r["children"])
    assert client.get("/neighbors", params={"id": 10**9}).status_code == 404


def test_search_depth_is_reported_and_limits_connections():
    words = [{"text": "padre", "lang": "it"}, {"text": "paternalistic", "lang": "en"}]
    body = client.post("/scene", json={"words": words}).json()
    search = body["search"]
    assert search["max_cost"] == api.MAX_COST
    assert 0 < search["depth"] <= search["reached"] <= search["max_cost"]
    assert search["depth"] == max(c["depth"] for c in body["connections"])
    # a search shallower than the connection needs finds nothing
    shallow = client.post("/scene", json={"words": words,
                                          "max_cost": search["depth"] - 0.5}).json()
    assert meet_word(shallow, 0, 1) != ("la", "pater")
    assert shallow["search"]["reached"] <= search["depth"] - 0.5


def test_search_depth_bounds():
    words = [{"text": "padre", "lang": "it"}]
    assert client.post("/scene", json={"words": words, "max_cost": 0}).status_code == 422
    assert client.post("/scene", json={"words": words, "max_cost": 41}).status_code == 422


def test_no_false_link_through_template_flags_or_compound_parts():
    # {{surf|+suf|en|talk|ing}} once made "en" (the language code) a part of talking, and
    # "*bi- + *innan. The form is also Middle High German binnen" made *bi- come from binnen
    r = client.post("/scene", json={"lang": "en", "max_cost": 20, "words": [
        {"text": "talking"}, {"text": "about"}]}).json()
    assert r["connections"] == []
    w = client.get("/word", params={"text": "talking", "lang": "en"}).json()
    assert ("en", "en") not in {(n["lang"], n["word"]) for n in w["nodes"].values()}
