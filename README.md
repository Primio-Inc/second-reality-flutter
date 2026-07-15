# Second Reality — Flutter Port

Future Crew's legendary 1993 PC demo, **ported to Flutter and upgraded** — running
from one codebase on web, mobile, TV, and any other platform Flutter supports.

It is a port, not an emulation: every scene runs the original's own code and
data. And it is an upgrade: modern high-resolution rendering, AI-regenerated artwork,
and a 48 kHz soundtrack in place of the period 8-bit mix.

**▶ Run it in your browser: https://primio.dev/demo/second-reality-flutter/**

- Original source (public domain, Unlicense): https://github.com/mtuomi/SecondReality
- Architecture reference: Fabien Sanglard's code review — https://fabiensanglard.net/second_reality/

## Run

```sh
flutter pub get
flutter run -d chrome        # or -d macos, -d ios, -d android — one codebase
```

For a web build served locally (the clock is WebAudio there; on native it is
`audioplayers`):

```sh
flutter build web --pwa-strategy=none           # no stale service worker
(cd build/web && python3 -m http.server 8099)   # -> http://localhost:8099/
```

Click to start (browser autoplay policy).

On Android, `flutter build apk --release`. The app is **landscape-only** (the
demo is a 4:3 landscape field, so a portrait window would letterbox it into a
strip), and it holds a **wake lock** for as long as the demo is running, the way
a video player does — eleven minutes of watching with no input would otherwise
let the screen dim straight through the middle of it.

That same APK runs on **Android TV**. It declares a leanback launcher and a
320×180 banner, and — the part that actually decides it — declares the
touchscreen *not required*, which is implied-required by default and would
otherwise hide the app on TV entirely. It is drivable with a **D-pad**: the
remote lands on START, the centre button opens and closes the commentary, and
the arrows move between the panel's controls. (The demo's own arrow-key seek
applies only while the demo holds focus, or it would eat the only navigation a
remote has and trap focus on whatever it reached.)

| Key | Action |
|-----|--------|
| `I` | **live commentary** (also the ⓘ button, top right) |
| `1`–`9`, `P`, `F`, `L`, `R`, `Z`, `V`, `W`, `X`, `J`, `U`, `G`, `C`, `E` | jump to a scene |
| ← / → | seek ∓/± 5 s (visuals follow the music) |
| `T` / `S` | tablet frame / smooth upscale |
| `D` | debug HUD (and the scene menu) |

Any key held with ctrl/cmd/alt belongs to the browser, not to us — otherwise ⌘R
is read as a bare `R`, which jumps to the rotozoomer *and* swallows the reload.

The scene menu (every part, plus the set-pieces bookmarked inside them) lives
behind the debug HUD, `D`.

## Live commentary

The **ⓘ** button turns the demo into a documentary: a running transcript, keyed
to the same music clock the demo itself runs on, explaining what each part is,
how it was done in 1993, and what it cost to bring back. It scrolls rather than
flipping pages, so a slow reader never loses a card, and it can be scrolled back
through at any time. The footer shows the current part, the running time, and an
equaliser driven by the soundtrack's real spectrum (the web clock already taps
the output with an `AnalyserNode`).

Its spine is the one idea that explains almost every effect in the demo: **it is
not computing what you see, it is looking it up.** Refraction, occlusion, camera
paths, bounce physics, even the water were all baked offline in 1993, and at run
time the CPU is mostly copying memory.

**It has to be readable, and that is enforced.** A card is the current card until
the next one appends, and plenty of viewers do not read English natively, so
`tool/check_commentary_timing.py` holds every card to 130 words per minute of the
time it is actually on screen, and fails if one cannot be finished. That makes
the script a fixed pot of words, and it decides the layout: the effect cards sit
on their effect and cannot move, so the history — which explains no pixel — lives
in the end scroller, five minutes with nothing to narrate. Every historical claim
in it was web-searched, and the ones that could not be sourced were cut.

The script lives in `lib/commentary_script.dart` (the source of truth);
`reference/commentary.md` is generated from it by `tool/dump_commentary.py`.

## What's implemented

**All of it.** Every part of the original's own `partexecute` list
(`MAIN/U2.ASM`), in playback order:

the intro credits · the horizon scroll with the mothership flyover · the Praxis
explosion · the title · the glenz vector and checkerboard · the dot tunnel · the
interference rings · the techno boxes and the troll · the panic TV shutdown · the
forest scroller · the lens and rotozoomer · the plasma and the plasma cube · the
mini vector balls · the mirror-ball sword scroll · the 3D sinus field · the
jellypic · the vector city fly-through · the Future Crew logo · the 21 credit
screens · the end scroller.

(`DDSTARS` is not in that list: the loader gates it on a flag the shipped demo
never sets, so it never runs.)

## How it is built

- **The original source is vendored** at `original/`. Every part is ported from
  its C/ASM — the algorithm, the positions, the timing — not reconstructed by
  eye from the video.
- **Assets are converted, never hand-authored.** Python tools under `tool/` turn
  the original's pictures, compiled 3D scenes and precomputed tables into
  compact formats the engine reads (`.sri` pictures, `.srt` tables, `.srv`
  scenes), each verified against the original data.
- **The clock is the audio**, never wall time, so the visuals cannot drift. Parts
  trigger off the tracker's ROW grid — the same `dis_sync` / `dis_musrow` events
  the original keyed on — resolved through a row clock extracted from the music
  modules.
- **The soundtrack is our own render** of the two original S3M modules.
- **Architecture:** the port mirrors the original's structure. A `DemoTimeline`
  (the equivalent of the original DIS interrupt server) sequences self-contained
  `Part` classes, slaved to the audio playback position. 2D palette effects
  render into a VGA-style indexed framebuffer (`IndexedSurface`, 320×200 /
  320×400) scaled with crisp pixels; 3D vector elements render at native
  resolution over it.

## What is modernised

The code and data are the original's. A few things are deliberately not:

- **Upgraded visuals.** Text is drawn with a clean vector font rather than the
  original's 8×8 bitmap (which was incomplete — its caps set has no Y or Z, so
  "DOLBY" shipped as "DOLB"), and 3D renders smoothly at native resolution
  instead of in chunky pixels. Five pictures — the title splash, the intro
  horizon, the techno troll, the jellypic and the Future Crew logo — are
  **regenerated with an AI image model**, then quantised straight back into the demo's own indexed VGA
  format, so every palette trick that operates on them (fades, the troll's ripple
  and colour flash, the TV-shutdown that reads the DAC back) still runs
  untouched. Each one's original pixels are one command away.
- **Smoother 3D.** The two vector parts replay the original's compiled animation
  stream, which stores one pose per retrace. We sample it at a *fractional*
  frame, so the camera and the objects move continuously at the display's refresh
  rate instead of stepping on the original's grid — the data is untouched, only
  the sampling rate changes, and hard cuts still snap.
- **Our own pictures in the credits.** The 21 credit screens each show a
  thumbnail of the part they credit. The original's are 160×100 pixel art (and
  one of them was never finished — it is a hand-scrawled "PARTPIC MISSING"
  placeholder), so instead each screen shows this port's own render of that part,
  shot straight out of the running demo. Same screens, same order, same lines,
  same slide.
- **Upgraded soundtrack.** Rendered from the original S3M modules at **48 kHz
  stereo** (Vorbis q6), instead of the period 8-bit SoundBlaster mix — and with
  zero drift against the row clock the visuals sync to, which the mastered rips
  floating around do not have. It is also **remixed in stereo**: the modules
  carry ST3's SoundBlaster panning (every voice hard-ish left or right, at about
  20/80), so a pan table re-places the eight channels, the low end is collapsed
  to mono, and a stereo room is added for depth. Swap or disable it with
  `tool/render_soundtrack.py --mix <preset>`; `tool/audition_stereo.py` renders
  every preset with excerpts to A/B. Nothing in the chain may move a sample —
  the demo syncs on tracker rows — so every render asserts the same length and
  zero lag against the unmixed one, and that it stays mono-compatible.

- **An app icon and a TV banner.** The launcher icon is the LENS monster's head,
  taken from the demo's own picture (not regenerated) by `tool/make_app_icon.py`,
  shipped as an adaptive icon so a circular mask cannot clip his ears.

## Credits

*Second Reality* is by **Future Crew** (1993) — code by Psi, Trug, Wildfire and
Yzi; music by Purple Motion and Skaven; graphics by Pixel. This is an
unaffiliated fan port.

This port was created by the team behind [primio.dev](https://primio.dev) with
Claude Code for the code porting, and Gemini and ChatGPT for image generation. We
also used YouTube recordings of the original demo for matching frames, and
[Fabien Sanglard's Second Reality breakdown](https://fabiensanglard.net/second_reality/)
for context.

A few pictures (the title splash, the intro horizon, the techno troll, the
jellypic, the FC logo) are AI-regenerated rather than the original pixels, and the credit
screens' thumbnails are this port's own renders; each original can be restored by
re-running its converter (see `tool/`).

## License

This port — the code under `lib/`, `tool/`, `android/`, `web/`, and the
converted files under `assets/` — is released under the **MIT License** (see
`LICENSE`).

The bundled third-party material keeps its own terms, and none of it falls
under the MIT license above (see `THIRD-PARTY-NOTICES.md`):

- **`original/`** — Future Crew's original 1993 source, public domain under the
  Unlicense (`original/UNLICENSE`, provenance in `original/VENDORED.md`).
- **The soundtrack and modules** (`assets/music/`, `reference/music/`) — music
  by Future Crew, public domain as part of that original release.
- **`assets/fonts/EBGaramond.ttf`** — SIL Open Font License
  (`assets/fonts/EBGaramond-OFL.txt`).
