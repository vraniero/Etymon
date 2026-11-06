"""Conversation listening: segmenting, voices, and the /listen protocol (models faked)."""
import numpy as np
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import listen
from listen import RATE, Segmenter, Session, Voices


def tone(seconds, freq=220.0, loud=0.2):
    t = np.arange(int(seconds * RATE)) / RATE
    return (loud * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def quiet(seconds):
    return np.zeros(int(seconds * RATE), np.float32)


def pcm(audio):
    return (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()


class FakeEngine:
    """A voice is its pitch: the embedding points one way per frequency. Says what it's told."""

    def __init__(self, words=("farmacia", "aperta"), lang="it"):
        self.words, self.lang = list(words), lang
        self.fallbacks = []

    def load(self):
        pass

    def embed(self, audio):
        spectrum = np.abs(np.fft.rfft(audio, RATE))[:1000]
        e = np.zeros(10)
        e[int(np.argmax(spectrum)) // 100] = 1
        return e + 0.05

    def transcribe(self, audio, fallback):
        self.fallbacks.append(fallback)
        n = len(self.words)
        span = len(audio) / RATE
        return self.lang, [{"text": w, "start": i * span / n, "end": (i + 1) * span / n}
                           for i, w in enumerate(self.words)]


def events(segmenter, audio, chunk=1600):
    out = []
    for i in range(0, len(audio), chunk):
        out += list(segmenter.feed(audio[i:i + chunk]))
    return out


def test_segmenter_cuts_at_pauses_and_keeps_stream_time():
    audio = np.concatenate([quiet(0.5), tone(1.0), quiet(1.0), tone(1.5), quiet(1.0)])
    found = events(Segmenter(), audio)
    kinds = [e[0] for e in found]
    assert kinds == ["speech", "silence", "utterance", "speech", "silence", "utterance"]
    starts = [e[1] for e in found if e[0] == "utterance"]
    assert starts == pytest.approx([0.5, 2.5], abs=0.04)
    lengths = [len(e[2]) / RATE for e in found if e[0] == "utterance"]
    assert lengths == pytest.approx([1.0, 1.5], abs=0.04)  # trailing quiet trimmed


def test_segmenter_drops_clicks_and_cuts_monologues():
    seg = Segmenter(longest=3.0)
    click = events(seg, np.concatenate([tone(0.1), quiet(1.0)]))
    assert [e[0] for e in click] == ["speech", "silence"]  # too short to be an utterance
    long = events(seg, tone(7.0))
    assert sum(e[0] == "utterance" for e in long) == 2  # cut at 3 s, 3 s; the rest pending
    assert [e[0] for e in seg.flush()] == ["silence", "utterance"]


def test_voices_cluster_and_merge():
    voices = Voices()
    a, b = np.eye(4)[0], np.eye(4)[1]
    p1, new1, _ = voices.assign(a)
    p2, new2, _ = voices.assign(b)
    p3, new3, score = voices.assign(a + 0.1 * b)
    assert (p1.id, p2.id, p3.id) == ("P1", "P2", "P1")
    assert (new1, new2, new3) == (True, True, False)
    assert score > 0.9
    voices.merge("P1", "P2")
    assert [p.id for p in voices.personas] == ["P1"]
    assert voices.assign(b)[0].id == "P1"


def test_session_attributes_words_to_personas_in_stream_time():
    engine = FakeEngine()
    session = Session(engine)
    first = session.hear(10.0, tone(1.0, 220))
    second = session.hear(12.0, tone(1.0, 660))
    third = session.hear(14.0, tone(1.0, 220))
    assert [u["persona"] for u in (first, second, third)] == ["P1", "P2", "P1"]
    assert [u["new_persona"] for u in (first, second, third)] == [True, True, False]
    assert third["words"][0]["start"] == 14.0 and third["words"][1]["end"] == 15.0
    assert third["text"] == "farmacia aperta" and third["lang"] == "it"
    assert engine.fallbacks == [None, None, "it"]  # a known voice's language is the fallback


def test_session_ignores_sounds_without_words_and_maps_serbo_croatian():
    engine = FakeEngine(words=[])
    session = Session(engine)
    assert session.hear(0.0, tone(1.0)) is None
    assert session.voices.personas == []  # noise doesn't become a persona
    engine.words, engine.lang = ["noć"], "hr"
    assert session.hear(1.0, tone(1.0))["lang"] == "sh"


def test_listen_websocket(monkeypatch):
    monkeypatch.setattr(listen, "engine", FakeEngine())
    app = FastAPI()
    app.include_router(listen.router)
    with TestClient(app).websocket_connect("/listen") as ws:
        assert ws.receive_json() == {"type": "ready"}
        audio = np.concatenate([quiet(0.3), tone(1.0, 220), quiet(1.0),
                                tone(1.0, 660), quiet(1.0)])
        for i in range(0, len(audio), 3200):
            ws.send_bytes(pcm(audio[i:i + 3200]))
        got = [ws.receive_json() for _ in range(6)]
        utterances = [m for m in got if m["type"] == "utterance"]
        assert [m["persona"] for m in utterances] == ["P1", "P2"]
        assert [m["id"] for m in utterances] == [1, 2]
        assert utterances[0]["start"] == pytest.approx(0.3, abs=0.04)
        assert [m["type"] for m in got if m["type"] != "utterance"] == \
            ["speech", "silence", "speech", "silence"]
        ws.send_text('{"type": "merge", "keep": "P1", "drop": "P2"}')
        for i in range(0, 3 * RATE, 3200):
            ws.send_bytes(pcm(np.concatenate([tone(1.0, 660), quiet(2.0)])[i:i + 3200]))
        got = [ws.receive_json() for _ in range(3)]
        assert [m["persona"] for m in got if m["type"] == "utterance"] == ["P1"]
