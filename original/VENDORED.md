# Original Second Reality source (vendored)

The complete original source of Future Crew's *Second Reality* (1993), as
released by the authors at **https://github.com/mtuomi/SecondReality** and
placed in the **public domain** under the Unlicense (see `UNLICENSE`).
Upstream's own readme is `README.md`; this file is ours.

It is vendored here — rather than cloned to a scratch path — so the port always
has its ground truth alongside it: every part's C/ASM/Pascal, the data tables,
the 3D Studio `.PRJ` scenes, and the LBM/FLI art that `../assets/` is converted
from.

**Do not modify anything in this directory.** It is a reference copy; the
conversion tooling in `../tool/` reads out of it.

## One deliberate omission

`MAIN/MUSIC0.S3M.wav` (350 MB) is NOT included — it is a decoded WAV render, not
source. The actual music source, `MAIN/MUSIC0.S3M`, is here. Everything else
from the upstream tree is present (1291 files, ~27 MB).

## Where the ported parts came from

| Port | Original |
|---|---|
| `p01_credits`, `p02_horizon` | `ALKU/MAIN.C`, `ALKU/HOI.LBM` |
| intro ship flyover | `VISU/C/SCENE/U2A.PRJ` |
| `p03_explosion` | `PAM/PRAX4.FLI`, `PAM/OUTTAA.C` |
| `p04_title` | `BEG/BEG.C`, `BEG/SRTITLE.LBM` |
| `p05_glenz` | `GLENZ/MAIN.C`, `GLENZ/VEC.ASM`, `GLENZ/NEW.ASM`, `GLENZ/FC.LBM` |
| `p06_tunnel` | `TUNNELI/TUN10.PAS`, `TUNNELI/TUNNEL.DAT`, `TUNNELI/SINIT.DAT` |
