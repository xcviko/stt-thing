"""Word-level LocalAgreement for realtime transcription.

Every decode of the current audio window gives a hypothesis: a list of words
with absolute timestamps. A word becomes committed (it will not change on
screen again) when two hypotheses in a row agree on it. This is the
LocalAgreement-2 policy (see ufal/whisper_streaming). RealtimeSTT does a
similar check per character offset; per-word is simpler and does not break
when the model rewrites an earlier word.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

_NORM_RE = re.compile(r"[^\w']+")
_SENTENCE_END = (".", "?", "!")

# Parakeet timestamps are quantized to 80 ms encoder frames and jitter a bit
# between decodes.
TIME_TOLERANCE = 0.15


@dataclass
class Word:
    text: str  # raw text with punctuation, no leading space
    start: float  # absolute seconds from segment start
    end: float

    @property
    def norm(self) -> str:
        return _NORM_RE.sub("", self.text.lower())

    @property
    def ends_sentence(self) -> bool:
        return self.text.endswith(_SENTENCE_END)


def words_from_tokens(tokens, offset: float = 0.0) -> list[Word]:
    """Groups parakeet subword tokens into words.

    A token that starts with a space opens a new word. Punctuation-only tokens
    and subword continuations are added to the current word.
    """

    words: list[Word] = []
    for tok in tokens:
        text = tok.text
        start = tok.start + offset
        end = tok.start + tok.duration + offset
        if not text.strip():
            continue
        if text.startswith(" ") or not words:
            words.append(Word(text.strip(), start, end))
            continue
        words[-1].text += text
        if _NORM_RE.sub("", text):
            words[-1].end = end
    return [w for w in words if w.norm]


def join_words(words: list[Word]) -> str:
    return " ".join(w.text for w in words)


class LocalAgreement:
    """Commits the longest common word prefix of the last two hypotheses."""

    def __init__(self) -> None:
        self.committed: list[Word] = []
        self.pending: list[Word] = []  # previous hypothesis, uncommitted part

    @property
    def committed_end(self) -> float:
        return self.committed[-1].end if self.committed else 0.0

    def _new_part(self, hypothesis: list[Word]) -> list[Word]:
        """Returns the part of a hypothesis after the committed words."""

        if self.committed:
            last = self.committed[-1]
            # Take punctuation for the last committed word from the newest
            # hypothesis: it has more right context ("please?" -> "please").
            for w in hypothesis:
                if w.norm == last.norm and abs(w.start - last.start) <= TIME_TOLERANCE * 2:
                    last.text = w.text
                    break

        last_t = self.committed_end
        new = [w for w in hypothesis if w.start > last_t - TIME_TOLERANCE]

        # The window can still include audio of committed words. Drop words
        # that repeat the committed tail (largest n-gram first).
        if new and self.committed and abs(new[0].start - last_t) < 1.0:
            max_n = min(5, len(self.committed), len(new))
            for n in range(max_n, 0, -1):
                if [w.norm for w in self.committed[-n:]] == [w.norm for w in new[:n]]:
                    new = new[n:]
                    break
        return new

    def update(self, hypothesis: list[Word], audio_end: float, settle: float = 0.4) -> list[Word]:
        """Adds a hypothesis. Returns the words that were committed now.

        Words in the common prefix of this and the previous hypothesis are
        committed. The last word of that prefix may still be in progress
        ("watch" before "walk me"), so it is committed only when the next word
        also agrees or when at least `settle` seconds of audio follow it.
        """

        new = self._new_part(hypothesis)
        agreed = 0
        while (
            agreed < len(new)
            and agreed < len(self.pending)
            and new[agreed].norm == self.pending[agreed].norm
        ):
            agreed += 1
        n = agreed
        if n and new[n - 1].end > audio_end - settle:
            n -= 1
        newly = new[:n]
        self.committed.extend(newly)
        self.pending = new[n:]
        return newly

    def force_commit(self, hypothesis: list[Word], until: float | None = None) -> list[Word]:
        """Commits words without agreement (end of segment, overlong window)."""

        new = self._new_part(hypothesis)
        if until is not None:
            new = [w for w in new if w.end <= until]
        self.committed.extend(new)
        self.pending = [w for w in self.pending if w.start > self.committed_end - TIME_TOLERANCE]
        return new

    def committed_text(self) -> str:
        return join_words(self.committed)

    def tentative_text(self) -> str:
        return join_words(self.pending)
