"""Conversation listening: a live audio stream in, who said which words out.

    WS /listen
      in   binary frames: 16 kHz mono PCM, 16-bit little-endian, any chunk size
           text frames (JSON):
             {"type": "merge", "keep": "P1", "drop": "P3"}   two voices are one person
             {"type": "reset"}                                forget voices, restart the clock
      out  {"type": "ready", "languages": ["de", "en", ...]}  models loaded
           {"type": "speech", "start": 12.40}                 someone started talking
           {"type": "silence", "end": 15.10, "kept": true}    ... and stopped (kept: long
                                                              enough to be transcribed)
           {"type": "unheard", "start": 12.4, "end": 15.1}    transcribed: no words in it
           {"type": "utterance", "id": 3, "persona": "P2", "new_persona": false,
            "similarity": 0.81, "lang": "it", "detected": "it", "start": 12.4, "end": 15.1,
            "text": "La farmacia è aperta", "words": [{"text": "farmacia", "start": 12.6,
            "end": 13.1}, ...]}

"lang" is the language the words are looked up in (null: not one the backend knows);
"detected" is what Whisper heard, even a language the backend doesn't know.

Times are seconds of audio since the stream (or the last reset) began, so the phone can
line them up with what its camera saw: whose mouth was moving, which screen was on.

Speech is cut into utterances at pauses; each is transcribed with Whisper (the language
detected per utterance, so a conversation can switch languages) and its voice compared
with the voices heard so far. A voice close enough to one already known is that persona;
otherwise it is a new one.

Needs: pip install mlx-whisper speechbrain soundfile  (Apple Silicon; models download on
first use: whisper-large-v3-turbo ~1.6 GB, ECAPA speaker model ~80 MB).
"""
import asyncio
import json
import logging
import threading
from dataclasses import dataclass, field

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

RATE = 16_000
FRAME = 480  # 30 ms
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
SPEAKER_MODEL = "speechbrain/spkrec-ecapa-voxceleb"
# The backend's languages, by the codes Whisper uses (Serbo-Croatian is hr, sr or bs).
LANGUAGES = {"it", "en", "es", "fr", "de", "ru", "uk", "be", "bg", "mk", "hr", "sr", "bs",
             "pl", "cs", "sk", "sl", "ro", "hu", "et", "lt", "lv"}
WIKTIONARY = {"hr": "sh", "sr": "sh", "bs": "sh"}

log = logging.getLogger("etymon")
router = APIRouter()


# --- cutting the stream into utterances ------------------------------------------------

class Segmenter:
    """Energy-based voice activity: an utterance runs from the first loud frame to a pause.

    The noise floor follows the quiet frames, so a noisy room needs louder speech. An
    utterance ends after `pause` seconds of quiet, or is cut at `longest` seconds (a
    monologue still arrives in pieces); anything shorter than `shortest` is a noise.
    """

    def __init__(self, pause=0.7, longest=12.0, shortest=0.4, floor=0.004):
        self.pause, self.longest, self.shortest = pause, longest, shortest
        self.floor = floor
        self.samples = 0  # stream position, in samples
        self._pending = np.zeros(0, np.float32)
        self._utterance: list[np.ndarray] = []
        self._start = 0
        self._quiet = 0  # frames of quiet inside the current utterance

    @property
    def talking(self):
        return bool(self._utterance)

    def feed(self, audio: np.ndarray):
        """Yield ("speech", start) / ("silence", end, kept) / ("utterance", start, audio) events:
        kept says an utterance follows (it was long enough, not a click)."""
        self._pending = np.concatenate([self._pending, audio])
        while len(self._pending) >= FRAME:
            frame, self._pending = self._pending[:FRAME], self._pending[FRAME:]
            yield from self._frame(frame)

    def _frame(self, frame):
        rms = float(np.sqrt(np.mean(frame ** 2)))
        loud = rms > max(self.floor * 3, 0.008)
        if not loud:  # adapt slowly to the room
            self.floor = 0.95 * self.floor + 0.05 * rms
        position = self.samples
        self.samples += len(frame)
        if not self._utterance:
            if loud:
                self._start, self._quiet = position, 0
                self._utterance = [frame]
                yield ("speech", position / RATE)
            return
        self._utterance.append(frame)
        self._quiet = 0 if loud else self._quiet + 1
        length = len(self._utterance) * FRAME / RATE
        if self._quiet * FRAME / RATE >= self.pause or length >= self.longest:
            yield from self._close()

    def flush(self):
        if self._utterance:
            yield from self._close()

    def _close(self):
        frames = self._utterance[:len(self._utterance) - self._quiet] or self._utterance
        audio = np.concatenate(frames)
        start = self._start / RATE
        self._utterance, self._quiet = [], 0
        kept = len(audio) / RATE >= self.shortest
        yield ("silence", start + len(audio) / RATE, kept)
        if kept:
            yield ("utterance", start, audio)


# --- telling voices apart -------------------------------------------------------------

@dataclass
class Persona:
    id: str
    centroid: np.ndarray
    count: int = 1
    lang: str | None = None  # the language they spoke last


@dataclass
class Voices:
    """Online clustering of voice embeddings: each voice heard is a persona.

    An utterance whose voice is at least `threshold` similar (cosine) to a persona's
    average voice is theirs, and refines that average; otherwise a new persona begins.
    The same speaker scores ~0.6-0.8 between utterances, different speakers ~0.0-0.3.
    """
    threshold: float = 0.45
    personas: list[Persona] = field(default_factory=list)
    _next: int = 1

    def match(self, embedding: np.ndarray) -> tuple[Persona | None, float]:
        """The persona this voice belongs to (None: a new voice), and how close it is."""
        e = embedding / (np.linalg.norm(embedding) or 1)
        best, score = None, -1.0
        for p in self.personas:
            s = float(e @ p.centroid)
            if s > score:
                best, score = p, s
        return (best if score >= self.threshold else None), max(score, 0.0)

    def assign(self, embedding: np.ndarray) -> tuple[Persona, bool, float]:
        """Match the voice and learn from it: refine the persona, or begin a new one."""
        e = embedding / (np.linalg.norm(embedding) or 1)
        best, score = self.match(e)
        if best is not None:
            # running mean, kept unit length; early utterances count more than later ones
            weight = 1 / min(best.count + 1, 10)
            mixed = (1 - weight) * best.centroid + weight * e
            best.centroid = mixed / np.linalg.norm(mixed)
            best.count += 1
            return best, False, score
        persona = Persona(f"P{self._next}", e)
        self._next += 1
        self.personas.append(persona)
        return persona, True, score

    def merge(self, keep: str, drop: str):
        a = next((p for p in self.personas if p.id == keep), None)
        b = next((p for p in self.personas if p.id == drop), None)
        if not a or not b or a is b:
            return
        mixed = a.count * a.centroid + b.count * b.centroid
        a.centroid, a.count = mixed / np.linalg.norm(mixed), a.count + b.count
        self.personas.remove(b)


# --- models -----------------------------------------------------------------------------

class Engine:
    """Whisper for the words, ECAPA for the voice. Loaded once, used one call at a time."""

    def __init__(self):
        self._lock = threading.Lock()
        self._encoder = None

    def load(self):
        with self._lock:
            if self._encoder is None:
                import mlx_whisper
                import torch
                from speechbrain.inference.speaker import EncoderClassifier
                self._torch, self._whisper = torch, mlx_whisper
                self._encoder = EncoderClassifier.from_hparams(
                    source=SPEAKER_MODEL, run_opts={"device": "cpu"})
                # a second of silence makes Whisper load its weights now, not mid-conversation
                mlx_whisper.transcribe(np.zeros(RATE, np.float32), path_or_hf_repo=WHISPER_MODEL)

    def embed(self, audio: np.ndarray) -> np.ndarray:
        with self._lock:
            tensor = self._torch.from_numpy(audio)[None]
            return self._encoder.encode_batch(tensor).squeeze().numpy()

    def transcribe(self, audio: np.ndarray, fallback: str | None
                   ) -> tuple[str | None, list[dict], str | None]:
        """The language spoken (if the backend knows it), the words with their times
        (seconds into `audio`), and the language Whisper detected.

        A language the backend doesn't know (a misdetection, usually) is retried as the
        speaker's previous language."""
        with self._lock:
            kw = dict(path_or_hf_repo=WHISPER_MODEL, word_timestamps=True,
                      condition_on_previous_text=False)
            result = self._whisper.transcribe(audio, **kw)
            lang = detected = result.get("language")
            if lang not in LANGUAGES and fallback:
                result = self._whisper.transcribe(audio, language=fallback, **kw)
                lang = fallback
        words = [{"text": w["word"].strip(), "start": round(float(w["start"]), 2),
                  "end": round(float(w["end"]), 2)}
                 for s in result.get("segments", []) for w in s.get("words", [])
                 if w["word"].strip()]
        return (lang if lang in LANGUAGES else None), words, detected


engine = Engine()


# --- the stream ------------------------------------------------------------------------

class Session:
    """One phone listening: its voices, its clock, its utterances in order."""

    def __init__(self, engine):
        self.engine = engine
        self.segmenter = Segmenter()
        self.voices = Voices()
        self.next_id = 1

    def hear(self, start: float, audio: np.ndarray) -> dict | None:
        embedding = self.engine.embed(audio)
        known, _ = self.voices.match(embedding)
        lang, words, detected = self.engine.transcribe(audio, fallback=known.lang if known else None)
        end = round(start + len(audio) / RATE, 2)
        if not words:  # a cough, a door: not speech after all, and no one's voice
            return {"type": "unheard", "start": round(start, 2), "end": end}
        persona, new, similarity = self.voices.assign(embedding)
        if lang:
            persona.lang = lang
        for w in words:
            w["start"] = round(start + w["start"], 2)
            w["end"] = round(start + w["end"], 2)
        out = {"type": "utterance", "id": self.next_id, "persona": persona.id,
               "new_persona": new, "similarity": round(similarity, 2),
               "lang": WIKTIONARY.get(lang, lang) if lang else None, "detected": detected,
               "start": round(start, 2), "end": end,
               "text": " ".join(w["text"] for w in words), "words": words}
        self.next_id += 1
        return out


@router.websocket("/listen")
async def listen(ws: WebSocket):
    await ws.accept()
    await asyncio.to_thread(engine.load)
    session = Session(engine)
    queue: asyncio.Queue = asyncio.Queue()
    await ws.send_json({"type": "ready", "languages": sorted(LANGUAGES)})
    log.info("listen  connected")

    async def work():
        # utterances are transcribed one after another, in the order they were spoken
        while True:
            start, audio, generation = await queue.get()
            out = await asyncio.to_thread(session.hear, start, audio)
            if generation != session_generation[0]:
                continue
            if out["type"] == "utterance":
                log.info(f"listen  {out['persona']}{'*' if out['new_persona'] else ''} "
                         f"[{out['lang'] or '--'}] {out['text']}")
            await ws.send_json(out)

    session_generation = [0]
    worker = asyncio.create_task(work())
    try:
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            if (data := message.get("bytes")) is not None:
                audio = np.frombuffer(data[: len(data) // 2 * 2], "<i2").astype(np.float32) / 32768
                for event in session.segmenter.feed(audio):
                    if event[0] == "utterance":
                        queue.put_nowait((event[1], event[2], session_generation[0]))
                    elif event[0] == "speech":
                        await ws.send_json({"type": "speech", "start": round(event[1], 2)})
                    else:
                        await ws.send_json({"type": "silence", "end": round(event[1], 2),
                                            "kept": event[2]})
            elif (text := message.get("text")) is not None:
                command = json.loads(text)
                if command.get("type") == "merge":
                    session.voices.merge(command.get("keep"), command.get("drop"))
                elif command.get("type") == "reset":
                    session_generation[0] += 1
                    session.segmenter = Segmenter()
                    session.voices = Voices()
    except WebSocketDisconnect:
        pass
    finally:
        worker.cancel()
        log.info("listen  disconnected")
