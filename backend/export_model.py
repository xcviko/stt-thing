"""Saves the speech model with its encoder already quantized, for release builds.

    python export_model.py OUT_DIR [--model ID]

The folder has config.json (with a "quantization" entry), model.safetensors,
the tokenizer files and the upstream README for attribution. stt_server.py
loads it with --model OUT_DIR. Saving it quantized keeps the app smaller
(~0.75 GB instead of ~1.25 GB) and the first load lighter.
"""

import argparse
import json
import shutil
from pathlib import Path

import mlx.core as mx
from huggingface_hub import snapshot_download
from mlx.utils import tree_flatten

from stt_server import DEFAULT_MODEL, ENCODER_QUANT, load_parakeet


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out", type=Path)
    p.add_argument("--model", default=DEFAULT_MODEL)
    args = p.parse_args()

    src = Path(snapshot_download(args.model))
    model = load_parakeet(args.model)  # encoder quantized on load

    args.out.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(args.out / "model.safetensors"), dict(tree_flatten(model.parameters())))
    config = json.loads((src / "config.json").read_text())
    config["quantization"] = dict(ENCODER_QUANT, strategy="encoder_only", source=args.model)
    (args.out / "config.json").write_text(json.dumps(config))
    for f in ("tokenizer.model", "tokenizer.vocab", "vocab.txt", "README.md"):
        if (src / f).exists():
            shutil.copy(src / f, args.out / f)
    print(args.out)


if __name__ == "__main__":
    main()
