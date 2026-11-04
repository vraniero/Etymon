"""Stream a kaikki.org (wiktextract) language dump and keep only what the graph needs.

The raw dumps are several GB each; the slim output is a small gzipped JSONL with
word, pos, a short gloss, etymology text and the etymology templates that encode
relationships (inheritance, borrowing, roots, cognates, affixes).

Usage: python3 fetch.py Italian [English ...]
"""
import gzip
import json
import subprocess
import sys
from pathlib import Path

DATA = Path(__file__).parent / "data"
URL = "https://kaikki.org/dictionary/{0}/kaikki.org-dictionary-{1}.jsonl"

# Etymology templates that carry a relationship between two terms.
KEEP_TEMPLATES = {
    # ancestry
    "inh", "inh+", "inh-lite", "der", "der+", "der-lite", "uder",
    # borrowing / "transpollination"
    "bor", "bor+", "lbor", "slbor", "obor", "ubor", "lbor+", "slbor+",
    "learned borrowing", "semi-learned borrowing", "orthographic borrowing",
    "unadapted borrowing", "calque", "cal", "clq", "partial calque", "pcal",
    "semantic loan", "sl", "phono-semantic matching", "psm",
    # roots and relatives
    "root", "cog", "cognate", "doublet", "dbt",
    # newer all-in-one template (Wiktionary is migrating core entries to it)
    "etymon",
    # morphology
    "af", "affix", "prefix", "pre", "suffix", "suf", "compound", "com",
    "confix", "con", "blend", "surf",
}


def etymology_prose(text, word):
    """Drop the "Etymology tree" diagram that {{etymon}} puts before the sentences."""
    lines = text.split("\n")
    if lines and lines[0].strip() == "Etymology tree":
        for i, line in enumerate(lines[1:], 1):
            if line.strip() == word or line.rstrip().endswith(" " + str(word)):
                return "\n".join(lines[i + 1:]).strip()
    return text


def slim(entry):
    templates = []
    for t in entry.get("etymology_templates") or []:
        if t.get("name") not in KEEP_TEMPLATES:
            continue
        args = {k: v for k, v in (t.get("args") or {}).items()
                if v and (k.isdigit() or k in ("t", "gloss", "alt"))}
        templates.append({"n": t["name"], "a": args})
    gloss = ""
    lemma = None
    for sense in entry.get("senses") or []:
        if not gloss and sense.get("glosses"):
            gloss = sense["glosses"][0]
        # inflected/alternative forms point at their lemma ("padri" -> "padre")
        for link in (sense.get("form_of") or []) + (sense.get("alt_of") or []):
            lemma = lemma or link.get("word")
    return {
        "w": entry.get("word"),
        "l": entry.get("lang_code"),
        "p": entry.get("pos"),
        "g": gloss[:200],
        "e": etymology_prose(entry.get("etymology_text") or "", entry.get("word"))[:3000],
        "t": templates,
        "f": lemma,
    }


def fetch(language):
    out_path = DATA / f"{language}.slim.jsonl.gz"
    if out_path.exists():
        print(f"{language}: already done", flush=True)
        return
    raw_path = DATA / f"{language}.raw.jsonl"
    url = URL.format(language.replace(" ", "%20"), language.replace(" ", ""))
    # Download to disk first so a dropped connection resumes instead of restarting.
    # curl also uses the system certificate store (python.org builds often lack one).
    subprocess.run(["curl", "-sSfL", "-C", "-", "--retry", "20", "--retry-all-errors",
                    "--retry-delay", "10", "-o", raw_path, url], check=True)

    tmp_path = out_path.with_suffix(".tmp")
    count = 0
    with open(raw_path, encoding="utf-8") as src, \
            gzip.open(tmp_path, "wt", encoding="utf-8") as out:
        for raw in src:
            entry = json.loads(raw)
            if not entry.get("word"):
                continue
            out.write(json.dumps(slim(entry), ensure_ascii=False) + "\n")
            count += 1
    tmp_path.rename(out_path)
    raw_path.unlink()
    print(f"{language}: done, {count:,} entries -> {out_path.name}", flush=True)


if __name__ == "__main__":
    DATA.mkdir(exist_ok=True)
    for lang in sys.argv[1:]:
        fetch(lang)
