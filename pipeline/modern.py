"""The present-day languages Etymon reads: scene words are looked up in these, they are
ranked by frequency, and they are the living end of every network (descendants shown,
words kept in the mobile export). Codes are Wiktionary's.
"""
from wordfreq import available_languages, zipf_frequency

MODERN = (
    "en", "it", "es", "fr", "de",
    # East and South Slavic, Cyrillic script
    "ru", "uk", "be", "bg", "mk",
    # Serbo-Croatian (Cyrillic and Latin), West and South Slavic in Latin script
    "sh", "pl", "cs", "sk", "sl",
    # the rest of Central and Eastern Europe: Romance, Uralic, Baltic
    "ro", "hu", "et", "lt", "lv",
)

# wordfreq has no lists for some of them (Belarusian, Estonian): no frequency, not zero
HAS_FREQUENCY = set(MODERN) & set(available_languages())


def zipf(word, lang):
    """Word frequency on the Zipf scale (3 = once per million words); None when the
    language has no frequency list."""
    return zipf_frequency(word, lang) if lang in HAS_FREQUENCY else None
