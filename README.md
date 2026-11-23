# stt-thing

Live captions of the other side of a call, on a panel that stays on top of every window. Optionally translated
sentence by sentence.

Speech recognition runs on your Mac. Translation goes through OpenRouter or your own OpenAI-compatible endpoint.

## Install

Requires a Mac with Apple silicon, macOS 14 or later and [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)
(`brew install blackhole-2ch`).

1. Download the latest `stt-thing-<version>-arm64.zip` from [Releases](https://github.com/xcviko/stt-thing/releases),
   unzip it and move `stt-thing.app` to Applications.
2. The app isn't notarized by Apple, so macOS blocks it. Run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/stt-thing.app
   ```

3. Open it and allow Microphone access. macOS asks for it before any input can be read, BlackHole included.
4. The first launch installs Python packages (about 500 MB), which takes a minute or two. The panel shows the
   progress. Later launches take a few seconds.

To update, quit stt-thing (STT in the menu bar → Quit), replace the app in Applications and run the `xattr` command
again.

## Send the call's sound to BlackHole

1. Open Audio MIDI Setup, click "+" and choose Create Multi-Output Device.
2. Tick your headphones and BlackHole 2ch.
3. Pick this Multi-Output Device as the sound output in System Settings, or only in Zoom or Meet.

You hear the call as usual, and stt-thing reads BlackHole, its default input. To read another input, use Input
device in the menu.

## Use

| To | Do |
|---|---|
| Move the panel | drag its top bar |
| Resize it | drag the right edge, the bottom edge or the bottom right corner |
| Change how much room the translation gets | drag the line between the text and the translation |
| Stop listening and scroll back | ⏸ in the top bar, then scroll; ▶ to go back to live |
| Hide or show the panel | **⌥⌘T** |
| Open settings and costs | **⚙** in the top bar; Done goes back to the captions |
| Open the menu | **•••** in the top bar, right-click the top bar, the menu bar icon, or right-click the Dock icon |

The rest of the panel lets clicks through to the window below it.

Each phrase has a bar on its left: green while it's being said or translated, gray once it's done. Gray words at
the end of a line can still change.

The menu also has Input device, text size, background opacity, Clear text and Restart backend.

stt-thing shows an icon in the Dock and in the menu bar. Click the Dock icon to bring the panel back. Turn either off
in ⚙ → Settings → App; one of them always stays on.

**Hide from screen sharing** is on by default: it asks macOS to leave the panel out of screen sharing and
recordings. Some apps capture the screen in a way that ignores this, so check with yours before you rely on it.

## Translation

1. ⚙ in the top bar (or Menu → Settings…). The panel shows the settings in place of the captions.
2. Turn on Translate the transcript and pick the direction: English to Russian or Russian to English.
3. Pick a provider:
   - **OpenRouter**: paste your [OpenRouter key](https://openrouter.ai/keys). The model is Gemini 3.5 Flash Lite.
   - **Custom (OpenAI API)**: any endpoint that serves `/chat/completions`, with its key and model name. Enter its
     prices per million tokens if it doesn't report the cost itself.
4. Press Test. It translates one sentence and shows the result, the time it took and the price.

Each sentence is translated as soon as it's finished and appears in the right column a moment later.

**Send each sentence twice, show the faster answer** (in Settings) makes slow translations arrive about 0.3 s sooner.
It doubles the requests: twice the cost on OpenRouter.

## Cost

The top bar shows what translation has cost in this conversation. ⚙ → Cost & stats shows this conversation, today and
all time, with a chart per day and a list of past conversations. New conversation starts the count from zero.

With OpenRouter, a sentence costs a fraction of a cent.

## Your data

Everything stays in `~/Library/Application Support/stt-thing`: the Python packages, your keys, the cost history and
`backend.log`. Transcripts are never written to disk.

Keys are kept in a file readable only by your user account, not in the Keychain.

To remove stt-thing, delete the app and that folder.

## If something doesn't work

- **No text appears.** The dot in the top bar turns green when the app hears speech. If it never does, check Input
  device in the menu and that the call's sound goes to BlackHole.
- **"Backend stopped" or no Microphone prompt.** System Settings → Privacy & Security → Microphone: turn on stt-thing,
  then Restart backend in the menu.
- **Stuck on starting.** Send `~/Library/Application Support/stt-thing/backend.log`.

## Build from source

Requires Xcode and [uv](https://docs.astral.sh/uv/).

```sh
cd backend && uv sync
cd ../mac && ./scripts/make-cert.sh && ./make-app.sh
open build/stt-thing.app
```

`scripts/make-cert.sh` (once) creates the `stt-thing-dev` signing certificate in its own keychain. With it, macOS
remembers the Microphone permission across rebuilds; without it, every build is signed ad-hoc and asks again.

This build runs the speech backend straight from `backend/`. The first launch downloads the speech model (about
1.3 GB) from Hugging Face. To see the backend's output, run `swift run` in `mac/`.

The backend also works on its own, for example on a recording:

```sh
cd backend && uv run python stt_server.py --file call.wav
```

`python stt_server.py --help` lists the other flags.

### Releasing

`./make-app.sh --release x.y.z` builds a self-contained app (Python backend, uv and the speech model inside) and zips
it into `mac/build/release/`. It never pushes or publishes: it prints the `git push` and `gh release create`
commands to run yourself. Release notes rules are in `CLAUDE.md`.

## Credits

Speech recognition uses [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) by Moondream, a
post-trained version of [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA, in the
[MLX conversion](https://huggingface.co/selcukkubur/parakeet-ultra-mlx) by selcukkubur. All CC-BY-4.0.
