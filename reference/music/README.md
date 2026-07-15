# Reference music modules (tooling data — NOT bundled in the app)

`music0.s3m` and `music1.s3m` are **intact** copies of the two S3M modules used
by the demo's soundtrack:

| file | = original | title | size | speed/tempo | length |
|---|---|---|---|---|---|
| `music0.s3m` | `original/MAIN/MUSIC0.S3M` | "UnreaL ][ - The 2ND Reality" (Purple Motion) | 391312 bytes | 6 / 125 | 483.6s |
| `music1.s3m` | `original/MAIN/MUSIC1.S3M`  | "UnreaL ][ / PM" (Skaven?)                    | 600860 bytes | 3 / 130 | 404.8s |

Both are byte-size-identical to the vendored copies in `original/MAIN/`, i.e.
the same releases — but where the vendored `original/MAIN/MUSIC0.S3M` and
`MUSIC1.S3M` have **scrambled pattern data** (every parser we tried, including
libopenmpt, decodes them as 2-5 second songs instead of ~7-8 minutes), these
copies play correctly end to end.

**Do not use `original/MAIN/MUSIC0.S3M` / `MUSIC1.S3M` for row-timing
extraction or playback validation — they are corrupt.** `original/` is a
read-only vendored copy of the upstream repo and is left as-is (per
`original/VENDORED.md`); these intact copies live here instead, for tooling
that needs to actually decode/play the modules (e.g.
`tool/extract_music_rows.py`).

## Provenance

Downloaded from the modland mirror at `artscene.textfiles.com` (Purple
Motion / Skaven scene directories), matched to the vendored files by exact
byte size (391312 / 600860 bytes — same releases, uncorrupted).

## Alignment to the continuous soundtrack

`assets/music/soundtrack.ogg` (built by `tool/fetch_music.sh`) concatenates
the two modules' mastered renders. Each module's start offset in that
continuous track, measured by normalized cross-correlation of onset envelopes
(consistent to +-15ms across windows):

    music0.s3m -> soundtrack t =   0.090 s
    music1.s3m -> soundtrack t = 104.360 s

These offsets are the constants used by `tool/extract_music_rows.py` to
convert each module's internal row-clock time to soundtrack-absolute time.
