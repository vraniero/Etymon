"""Download Wiktionary's language, family and etymology-language tables as JSON.

languages.json       code -> {1: name, 3: family, ancestors}
families.json        code -> {1: name, 3: parent family}
etym_languages.json  code -> {1: name, parent: language}   (Late Latin, Vulgar Latin...)

Usage: python3 fetch_languages.py
"""
import json
import subprocess
from pathlib import Path

DATA = Path(__file__).parent / "data"
API = "https://en.wiktionary.org/w/api.php"
EXPORTS = {
    "languages.json": "{{#invoke:JSON data|export_languages||1|3|ancestors}}",
    "families.json": "{{#invoke:JSON data|export_families}}",
    "etym_languages.json": "{{#invoke:JSON data|export_etymology_languages}}",
}


def expand(wikitext):
    out = subprocess.run(
        ["curl", "-sSfG", API, "-A", "EtymonPipeline/0.1",
         "--data-urlencode", "action=expandtemplates",
         "--data-urlencode", f"text={wikitext}",
         "--data-urlencode", "prop=wikitext",
         "--data-urlencode", "format=json"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(json.loads(out)["expandtemplates"]["wikitext"])


if __name__ == "__main__":
    DATA.mkdir(exist_ok=True)
    for name, wikitext in EXPORTS.items():
        data = expand(wikitext)
        (DATA / name).write_text(json.dumps(data, ensure_ascii=False))
        print(f"{name}: {len(data):,}")
