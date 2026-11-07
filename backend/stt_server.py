"""Realtime transcription backend for stt-thing.

Reads audio from an input device (BlackHole by default) or a file, finds
speech segments with WebRTC VAD, decodes the current segment window with
parakeet-mlx a few times per second and commits words with LocalAgreement.

Output: one JSON object per line on stdout. Logs go to stderr.

  {"type": "ready", "device": ..., "model": ...}
  {"type": "level", "db": -32.5, "speech": true}
  {"type": "update", "seg": 3, "committed": "...", "tentative": "...", "final": false, ...}
  {"type": "paused", "paused": true}
  {"type": "error", "message": "..."}

Commands on stdin, one per line: "pause" (finish the current segment and
ignore audio until resumed; the model stays loaded) and "resume".
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import signal
import sys
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np
import soxr
import webrtcvad

from agreement import LocalAgreement, Word, words_from_tokens

SR = 16000
FRAME = 480  # 30 ms at 16 kHz, a frame size WebRTC VAD supports
FRAME_S = FRAME / SR

_stdout_lock = threading.Lock()


def emit(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False)
    with _stdout_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            # The UI that reads us is gone.
            os._exit(0)


def log(*args) -> None:
    print(*args, file=sys.stderr, flush=True)


stop = threading.Event()


def install_exit_handlers() -> None:
    """Makes sure the process never outlives its parent (Electron or uv)."""

    def on_signal(signum, frame):
        if stop.is_set():
            os._exit(1)  # second signal: give up on clean shutdown
        stop.set()
        # If the main loop is stuck in a decode, still exit soon.
        threading.Timer(2.0, lambda: os._exit(0)).start()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    parent = os.getppid()

    def watch_parent():
        while True:
            time.sleep(0.5)
            if os.getppid() != parent:
                os._exit(0)

    threading.Thread(target=watch_parent, daemon=True).start()


def start_command_reader(commands: queue.Queue) -> None:
    """Reads "pause" / "resume" lines from stdin."""

    def run():
        try:
            for line in sys.stdin:
                cmd = line.strip().lower()
                if cmd:
                    commands.put(cmd)
        except Exception:
            pass

    threading.Thread(target=run, daemon=True).start()


# ---------------------------------------------------------------- audio input


def list_devices() -> list[dict]:
    import sounddevice as sd

    out = []
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0:
            out.append({"index": i, "name": d["name"], "channels": d["max_input_channels"]})
    return out


def find_device(query: str | None):
    import sounddevice as sd

    if query is None or query == "":
        return None, sd.query_devices(kind="input")["name"]
    if query.isdigit():
        return int(query), sd.query_devices(int(query))["name"]
    for d in list_devices():
        if query.lower() in d["name"].lower():
            return d["index"], d["name"]
    raise SystemExit(f"Input device not found: {query!r}. Use --list-devices.")


class DeviceSource:
    """Captures mono float32 audio at 16 kHz from a sounddevice input."""

    def __init__(self, device_query: str | None, out: queue.Queue):
        import sounddevice as sd

        self.index, self.name = find_device(device_query)
        info = sd.query_devices(self.index if self.index is not None else None, kind="input")
        self.in_sr = int(info["default_samplerate"])
        channels = min(2, int(info["max_input_channels"]))
        self.resampler = soxr.ResampleStream(self.in_sr, SR, 1, dtype="float32")
        self.out = out

        def callback(indata, frames, t, status):
            if status:
                log("audio status:", status)
            mono = indata.mean(axis=1).astype(np.float32)
            y = self.resampler.resample_chunk(mono)
            if len(y):
                self.out.put(y)

        self.stream = sd.InputStream(
            device=self.index,
            channels=channels,
            samplerate=self.in_sr,
            blocksize=int(self.in_sr * 0.02),
            dtype="float32",
            callback=callback,
        )

    def start(self):
        self.stream.start()

    def stop(self):
        # abort() does not wait for pending buffers, so it cannot hang.
        self.stream.abort()


class FileSource:
    """Plays a 16 kHz mono wav into the pipeline at realtime speed (for tests)."""

    def __init__(self, path: str, out: queue.Queue, speed: float = 1.0):
        import soundfile as sf

        audio, sr = sf.read(path, dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        if sr != SR:
            audio = soxr.resample(audio, sr, SR).astype(np.float32)
        # Trailing silence so the last segment ends.
        self.audio = np.concatenate([audio, np.zeros(int(SR * 1.5), np.float32)])
        self.name = f"file:{path}"
        self.out = out
        self.speed = speed
        self.done = threading.Event()

    def _run(self):
        chunk = int(SR * 0.02)
        t0 = time.monotonic()
        for i in range(0, len(self.audio), chunk):
            self.out.put(self.audio[i : i + chunk])
            target = t0 + (i + chunk) / SR / self.speed
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
        self.done.set()

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def stop(self):
        pass


# ------------------------------------------------------------------- ASR


DEFAULT_MODEL = "sonic-speech/parakeet-tdt-0.6b-v3-int8"


def load_parakeet(model_id: str):
    """Loads a parakeet-mlx model, including quantized checkpoints.

    parakeet-mlx's from_pretrained fails on quantized weights (extra .scales
    and .biases), so quantize the layers that have .scales first and load the
    weights after that. Same approach as the telegram skill.
    """

    import mlx.core as mx
    import mlx.nn as nn
    from huggingface_hub import snapshot_download
    from parakeet_mlx.utils import from_config

    path = Path(snapshot_download(model_id))
    config = json.loads((path / "config.json").read_text())
    model = from_config(config)
    weights = mx.load(str(path / "model.safetensors"))
    quant = config.get("quantization")
    if quant:
        qlayers = {k.rsplit(".", 1)[0] for k in weights if k.endswith(".scales")}
        nn.quantize(
            model,
            group_size=quant["group_size"],
            bits=quant["bits"],
            class_predicate=lambda p, _: p in qlayers,
        )
    model.load_weights(list(weights.items()))
    mx.eval(model.parameters())
    return model


class Asr:
    def __init__(self, model_id: str):
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        self.mx = mx
        self.get_logmel = get_logmel
        self.model = load_parakeet(model_id)
        self.transcribe(np.zeros(SR, np.float32))  # warm-up

    def transcribe(self, audio: np.ndarray, offset: float = 0.0) -> list[Word]:
        if len(audio) < SR // 10:
            return []
        mel = self.get_logmel(self.mx.array(audio), self.model.preprocessor_config)
        result = self.model.generate(mel)[0]
        return words_from_tokens(result.tokens, offset)


# --------------------------------------------------------------- pipeline


class Segment:
    """One speech segment: audio since speech start, window and agreement state."""

    def __init__(self, seg_id: int, preroll: np.ndarray):
        self.id = seg_id
        self.chunks: list[np.ndarray] = [preroll] if len(preroll) else []
        self.samples = len(preroll)
        self.audio_cache: np.ndarray | None = None
        self.win_start = 0.0  # seconds; audio before it is not decoded again
        self.agreement = LocalAgreement()
        self.last_decoded_samples = 0
        self.silence_s = 0.0
        self.speech_s = 0.0

    def add(self, frame: np.ndarray):
        self.chunks.append(frame)
        self.samples += len(frame)
        self.audio_cache = None

    @property
    def duration(self) -> float:
        return self.samples / SR

    def audio(self) -> np.ndarray:
        if self.audio_cache is None:
            self.audio_cache = np.concatenate(self.chunks) if self.chunks else np.zeros(0, np.float32)
            self.chunks = [self.audio_cache]
        return self.audio_cache


class Pipeline:
    def __init__(self, args, asr: Asr, audio_q: queue.Queue):
        self.args = args
        self.asr = asr
        self.q = audio_q
        self.vad = webrtcvad.Vad(args.vad_mode)
        self.buf = np.zeros(0, np.float32)
        self.preroll: deque[np.ndarray] = deque(maxlen=max(1, int(args.preroll / FRAME_S)))
        self.recent_voiced: deque[bool] = deque(maxlen=10)  # last 300 ms
        self.seg: Segment | None = None
        self.seg_counter = 0
        self.last_decode_at = 0.0
        self.level_sum = 0.0
        self.level_n = 0
        self.last_level_at = 0.0
        self.stats: list[tuple[float, float]] = []  # (window seconds, ms)
        self.commands: queue.Queue[str] = queue.Queue()
        self.paused = False

    # ---- VAD

    def _is_speech(self, frame: np.ndarray) -> bool:
        rms = float(np.sqrt(np.mean(frame * frame)) + 1e-12)
        self.level_sum += rms
        self.level_n += 1
        if rms < self.args.min_rms:
            return False
        pcm = (np.clip(frame, -1, 1) * 32767).astype(np.int16).tobytes()
        return self.vad.is_speech(pcm, SR)

    def _process_frame(self, frame: np.ndarray):
        voiced = self._is_speech(frame)
        self.recent_voiced.append(voiced)

        if self.seg is None:
            self.preroll.append(frame)
            if sum(self.recent_voiced) >= self.args.start_frames:
                self.seg_counter += 1
                self.seg = Segment(self.seg_counter, np.concatenate(list(self.preroll)))
                self.preroll.clear()
                self.last_decode_at = time.monotonic()  # first decode after one interval
            return

        self.seg.add(frame)
        if voiced:
            self.seg.silence_s = 0.0
            self.seg.speech_s += FRAME_S
        else:
            self.seg.silence_s += FRAME_S
            if self.seg.silence_s >= self.args.silence:
                self._finish_segment()

    # ---- decoding

    def _decode(self, final: bool):
        seg = self.seg
        audio = seg.audio()
        start_sample = int(seg.win_start * SR)
        window = audio[start_sample:]
        t0 = time.perf_counter()
        words = self.asr.transcribe(window, offset=seg.win_start)
        ms = (time.perf_counter() - t0) * 1000
        self.stats.append((len(window) / SR, ms))
        seg.last_decoded_samples = seg.samples
        audio_end = seg.duration

        ag = seg.agreement
        if final:
            ag.force_commit(words)
            ag.pending = []
        else:
            ag.update(words, audio_end)
            self._maybe_trim_window(words, audio_end)

        emit(
            {
                "type": "update",
                "seg": seg.id,
                "committed": ag.committed_text(),
                "tentative": ag.tentative_text(),
                "final": final,
                "ms": round(ms),
                "window": round(len(window) / SR, 2),
                "t": round(audio_end, 2),
                # How far committed text trails the audio, seconds.
                "lag": round(audio_end - ag.committed_end, 2) if ag.committed else None,
            }
        )

    def _maybe_trim_window(self, words: list[Word], audio_end: float):
        """Keeps the decoded window short so each decode stays fast.

        The new window starts at the end of a committed word, preferably at a
        sentence end, and keeps about keep_window seconds of audio.
        """

        seg = self.seg
        if audio_end - seg.win_start <= self.args.max_window:
            return
        ag = seg.agreement
        target = audio_end - self.args.keep_window
        if ag.committed_end < target:
            # Agreement fell behind (very unstable audio). Commit what the
            # latest hypothesis says about the old audio and move on.
            ag.force_commit(words, until=target)
        candidates = [w for w in ag.committed if seg.win_start < w.end <= target]
        if not candidates:
            return
        sentence_ends = [w for w in candidates if w.ends_sentence]
        cut = (sentence_ends or candidates)[-1].end
        seg.win_start = cut

    def _finish_segment(self):
        seg = self.seg
        if seg.speech_s >= self.args.min_speech:
            self._decode(final=True)
        elif seg.agreement.committed or seg.agreement.pending:
            # Short blip that still produced text earlier: close it as final.
            self._decode(final=True)
        self.seg = None
        self.recent_voiced.clear()

    # ---- main loop

    def _emit_level(self):
        now = time.monotonic()
        if now - self.last_level_at < 0.1 or self.level_n == 0:
            return
        rms = self.level_sum / self.level_n
        self.level_sum = 0.0
        self.level_n = 0
        self.last_level_at = now
        emit({"type": "level", "db": round(20 * np.log10(rms + 1e-9), 1), "speech": self.seg is not None})

    def _handle_commands(self):
        while True:
            try:
                cmd = self.commands.get_nowait()
            except queue.Empty:
                return
            if cmd == "pause" and not self.paused:
                if self.seg is not None:
                    self._finish_segment()  # keep what was already said
                self.paused = True
                self.buf = np.zeros(0, np.float32)
                self.preroll.clear()
                self.recent_voiced.clear()
                emit({"type": "paused", "paused": True})
            elif cmd == "resume" and self.paused:
                self._drain_audio()
                self.paused = False
                emit({"type": "paused", "paused": False})

    def _drain_audio(self):
        while True:
            try:
                self.q.get_nowait()
            except queue.Empty:
                return

    def step(self, timeout: float = 0.01) -> None:
        self._handle_commands()
        if self.paused:
            # Audio keeps arriving from the device; drop it.
            try:
                self.q.get(timeout=0.05)
            except queue.Empty:
                pass
            self._drain_audio()
            return

        try:
            chunk = self.q.get(timeout=timeout)
            parts = [chunk]
            while True:
                try:
                    parts.append(self.q.get_nowait())
                except queue.Empty:
                    break
            self.buf = np.concatenate([self.buf, *parts])
        except queue.Empty:
            pass

        n = len(self.buf) // FRAME
        for i in range(n):
            self._process_frame(self.buf[i * FRAME : (i + 1) * FRAME])
        self.buf = self.buf[n * FRAME :]
        self._emit_level()

        seg = self.seg
        if seg is None:
            return
        now = time.monotonic()
        has_new_audio = seg.samples - seg.last_decoded_samples >= FRAME * 2
        if has_new_audio and now - self.last_decode_at >= self.args.interval and seg.speech_s > 0.1:
            self.last_decode_at = now
            self._decode(final=False)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default="BlackHole", help="input device name substring or index ('' = system default)")
    p.add_argument("--file", help="feed a wav file instead of a device (test mode)")
    p.add_argument("--speed", type=float, default=1.0, help="playback speed for --file")
    p.add_argument("--list-devices", action="store_true")
    p.add_argument("--model", default=DEFAULT_MODEL, help="Hugging Face id of a parakeet MLX model")
    p.add_argument("--interval", type=float, default=0.25, help="min seconds between decode starts")
    p.add_argument("--silence", type=float, default=0.7, help="silence that ends a segment, seconds")
    p.add_argument("--min-speech", type=float, default=0.25, help="ignore segments with less speech, seconds")
    p.add_argument("--preroll", type=float, default=0.3, help="audio kept before speech start, seconds")
    p.add_argument("--start-frames", type=int, default=4, help="voiced 30 ms frames out of 10 to start speech")
    p.add_argument("--vad-mode", type=int, default=2, choices=[0, 1, 2, 3])
    p.add_argument("--min-rms", type=float, default=0.002, help="frames quieter than this are silence")
    p.add_argument("--max-window", type=float, default=12.0, help="trim the decode window when longer")
    p.add_argument("--keep-window", type=float, default=5.0, help="audio kept in the window after trim")
    args = p.parse_args()

    if args.list_devices:
        emit({"type": "devices", "devices": list_devices()})
        return

    install_exit_handlers()

    audio_q: queue.Queue = queue.Queue()
    try:
        source = FileSource(args.file, audio_q, args.speed) if args.file else DeviceSource(args.device, audio_q)
    except SystemExit as e:
        emit({"type": "error", "message": str(e)})
        raise
    except Exception as e:
        emit({"type": "error", "message": f"Audio input error: {e}"})
        raise SystemExit(1)

    log(f"loading {args.model} ...")
    t0 = time.monotonic()
    asr = Asr(args.model)
    log(f"model ready in {time.monotonic() - t0:.1f}s")

    pipeline = Pipeline(args, asr, audio_q)
    start_command_reader(pipeline.commands)
    source.start()
    emit({"type": "ready", "device": source.name, "model": args.model})

    try:
        while not stop.is_set():
            pipeline.step()
            if args.file and source.done.is_set() and audio_q.empty() and pipeline.seg is None:
                break
    finally:
        try:
            source.stop()
        except Exception:
            pass
        if pipeline.stats:
            ms = np.array([s[1] for s in pipeline.stats])
            win = np.array([s[0] for s in pipeline.stats])
            log(
                f"decodes: {len(ms)}, ms avg {ms.mean():.0f} p95 {np.percentile(ms, 95):.0f} max {ms.max():.0f}; "
                f"window avg {win.mean():.1f}s max {win.max():.1f}s"
            )

    sys.stderr.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
