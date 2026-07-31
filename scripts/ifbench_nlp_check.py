#!/usr/bin/env python3
"""Source-derived IFBench NLP check bridge.

Imp ports most IFBench checks directly in Elixir. Five AllenAI IFBench
instructions depend on Python NLP packages upstream: langdetect, NLTK
stopwords/POS, emoji, and syllapy. This bridge provides a source-compatible path for parity
runs without making those Python packages normal Imp runtime dependencies.
"""

import json
import re
import string
import sys


_ALPHABETS = "([A-Za-z])"
_PREFIXES = "(Mr|St|Mrs|Ms|Dr)[.]"
_SUFFIXES = "(Inc|Ltd|Jr|Sr|Co)"
_STARTERS = r"(Mr|Mrs|Ms|Dr|Prof|Capt|Cpt|Lt|He\s|She\s|It\s|They\s|Their\s|Our\s|We\s|But\s|However\s|That\s|This\s|Wherever)"
_ACRONYMS = "([A-Z][.][A-Z][.](?:[A-Z][.])?)"
_WEBSITES = "[.](com|net|org|io|gov|edu|me)"
_DIGITS = "([0-9])"
_MULTIPLE_DOTS = r"\.{2,}"


def split_into_sentences(text):
    """Source-derived IFBench sentence splitter."""
    text = " " + text + "  "
    text = text.replace("\n", " ")
    text = re.sub(_PREFIXES, "\\1<prd>", text)
    text = re.sub(_WEBSITES, "<prd>\\1", text)
    text = re.sub(_DIGITS + "[.]" + _DIGITS, "\\1<prd>\\2", text)
    text = re.sub(
        _MULTIPLE_DOTS,
        lambda match: "<prd>" * len(match.group(0)) + "<stop>",
        text,
    )
    if "Ph.D" in text:
        text = text.replace("Ph.D.", "Ph<prd>D<prd>")
    text = re.sub(r"\s" + _ALPHABETS + "[.] ", " \\1<prd> ", text)
    text = re.sub(_ACRONYMS + " " + _STARTERS, "\\1<stop> \\2", text)
    text = re.sub(
        _ALPHABETS + "[.]" + _ALPHABETS + "[.]" + _ALPHABETS + "[.]",
        "\\1<prd>\\2<prd>\\3<prd>",
        text,
    )
    text = re.sub(_ALPHABETS + "[.]" + _ALPHABETS + "[.]", "\\1<prd>\\2<prd>", text)
    text = re.sub(" " + _SUFFIXES + "[.] " + _STARTERS, " \\1<stop> \\2", text)
    text = re.sub(" " + _SUFFIXES + "[.]", " \\1<prd>", text)
    text = re.sub(" " + _ALPHABETS + "[.]", " \\1<prd>", text)
    if "”" in text:
        text = text.replace(".”", "”.")
    if '"' in text:
        text = text.replace('."', '".')
    if "!" in text:
        text = text.replace('!"', '"!')
    if "?" in text:
        text = text.replace('?"', '"?')
    text = text.replace(".", ".<stop>")
    text = text.replace("?", "?<stop>")
    text = text.replace("!", "!<stop>")
    text = text.replace("<prd>", ".")
    sentences = [s.strip() for s in text.split("<stop>")]
    if sentences and not sentences[-1]:
        sentences = sentences[:-1]
    return sentences


def count_words(text):
    try:
        import nltk
    except ModuleNotFoundError as exc:
        raise RuntimeError("ratio:stop_words requires nltk") from exc

    tokenizer = nltk.tokenize.RegexpTokenizer(r"\w+")
    return tokenizer.tokenize(text)


def ratio_stop_words(args, value):
    try:
        import nltk
        from nltk.corpus import stopwords
    except ModuleNotFoundError as exc:
        raise RuntimeError("ratio:stop_words requires nltk") from exc

    try:
        stop_words = stopwords.words("english")
    except LookupError as exc:
        raise RuntimeError("ratio:stop_words requires NLTK stopwords corpus") from exc

    tokens = count_words(value)
    if not tokens:
        return False
    num_stopwords = len([token for token in tokens if token.lower() in stop_words])
    return (num_stopwords / len(tokens)) * 100 <= args.get("percentage", 0)


def format_emoji(_args, value):
    try:
        import emoji
    except ModuleNotFoundError as exc:
        raise RuntimeError("format:emoji requires emoji") from exc

    sentences = split_into_sentences(value)
    for index, sentence in enumerate(sentences):
        stripped = sentence.translate(str.maketrans("", "", string.punctuation)).strip()
        if not stripped:
            return False
        last_char = stripped[-1]
        second_last_char = stripped[-2] if len(stripped) > 1 else stripped[-1]
        if not emoji.is_emoji(last_char) and not emoji.is_emoji(second_last_char):
            if index < len(sentences) - 1:
                next_stripped = sentences[index + 1].translate(
                    str.maketrans("", "", string.punctuation)
                ).strip()
                if not next_stripped or not emoji.is_emoji(next_stripped[0]):
                    return False
            else:
                return False
    return bool(sentences)


def words_start_verb(_args, value):
    try:
        import nltk
    except ModuleNotFoundError as exc:
        raise RuntimeError("words:start_verb requires nltk") from exc

    try:
        text = nltk.word_tokenize(value)
        tagged = nltk.pos_tag(text)
    except LookupError as exc:
        raise RuntimeError(
            "words:start_verb requires NLTK punkt and averaged_perceptron_tagger_eng data"
        ) from exc

    return len(text) > 0 and len(tagged) > 0 and "VB" in tagged[0][1]


def words_odd_even_syllables(_args, value):
    try:
        import syllapy
    except ModuleNotFoundError as exc:
        raise RuntimeError("words:odd_even_syllables requires syllapy") from exc

    words = value.translate(str.maketrans("", "", string.punctuation)).lower().split()
    syllables = [syllapy.count(word) % 2 for word in words if word.strip()]
    return all(syllables[index] != syllables[index + 1] for index in range(len(syllables) - 1))


def language_response(args, value):
    try:
        import langdetect
    except ModuleNotFoundError as exc:
        raise RuntimeError("language:response_language requires langdetect") from exc

    try:
        return langdetect.detect(value) == args.get("language")
    except langdetect.LangDetectException:
        return False


CHECKS = {
    "language:response_language": language_response,
    "ratio:stop_words": ratio_stop_words,
    "format:emoji": format_emoji,
    "words:start_verb": words_start_verb,
    "words:odd_even_syllables": words_odd_even_syllables,
}


def main():
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    instruction_id = payload["instruction_id"]
    try:
        check = CHECKS[instruction_id]
    except KeyError as exc:
        raise RuntimeError(f"unsupported IFBench NLP bridge id: {instruction_id}") from exc

    following = check(payload.get("args", {}), payload.get("value", ""))
    print(json.dumps({"following": bool(following)}))


if __name__ == "__main__":
    main()
