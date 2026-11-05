"""The present-day languages Etymon reads: scene words are looked up in these, they are
ranked by frequency, and they are the living end of every network (descendants shown,
words kept in the mobile export). Codes are Wiktionary's.
"""
from functools import cache

MODERN = (
    "en", "it", "es", "fr", "de",
    # East and South Slavic, Cyrillic script
    "ru", "uk", "be", "bg", "mk",
    # Serbo-Croatian (Cyrillic and Latin), West and South Slavic in Latin script
    "sh", "pl", "cs", "sk", "sl",
    # the rest of Central and Eastern Europe: Romance, Uralic, Baltic
    "ro", "hu", "et", "lt", "lv",
)


# wordfreq is imported only when frequencies are needed (building the graph): the
# backend imports MODERN from here and doesn't have wordfreq installed.
@cache
def has_frequency():
    """Languages wordfreq has lists for; some (Belarusian, Estonian) have none: no
    frequency, not zero."""
    from wordfreq import available_languages
    return set(MODERN) & set(available_languages())


def zipf(word, lang):
    """Word frequency on the Zipf scale (3 = once per million words); None when the
    language has no frequency list."""
    if lang not in has_frequency():
        return None
    from wordfreq import zipf_frequency
    return zipf_frequency(word, lang)
