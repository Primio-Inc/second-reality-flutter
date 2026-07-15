import 'engine/demo_timeline.dart';
import 'engine/sync_table.dart';
import 'parts/p01_credits.dart';
import 'parts/p02_horizon.dart';
import 'parts/p03_explosion.dart';
import 'parts/p04_title.dart';
import 'parts/p05_glenz.dart';
import 'parts/p06_tunnel.dart';
import 'parts/p07_interference.dart';
import 'parts/p08_techno.dart';
import 'parts/p09_panic.dart';
import 'parts/p10_forest.dart';
import 'parts/p11_lens.dart';
import 'parts/p12_plasma.dart';
import 'parts/p13_minivectorballs.dart';
import 'parts/p14_rayscrl.dart';
import 'parts/p15_sinfield.dart';
import 'parts/p16_jplogo.dart';
import 'parts/p17_vector2.dart';
import 'parts/p18_endlogo.dart';
import 'parts/p19_credits.dart';
import 'parts/p20_endscroll.dart';

/// Demo script: part order and timings from the original sequence, aligned to
/// the continuous soundtrack. `start` is the music position (seconds) where each
/// scene begins; `name` labels it in the scene menu.
///
/// No start below is eyeballed. Where the original names a music cue, THAT is
/// the start: `dis_sync()` (DIS/DISINT.ASM `ordersync1`) maps a music
/// (order,row) to a part, and the row clock (`MusicRows`, built by
/// tool/extract_music_rows.py) turns it into a soundtrack time. A cue fires when
/// the part begins its FADE, so it LEADS the first visible pixel — never
/// "correct" a cue to the moment something becomes visible.
///
/// The rest are measured off the deterministic frame map
/// (`tool/analyze_video.py --scan A B 30`) and cross-checked against the onset
/// map (`tool/analyze_audio.py`). The soundtrack is our own render of the real
/// modules, so it does not drift against the row clock.
DemoTimeline buildDemoTimeline() => DemoTimeline(
      // TIMEBASE. MUSIC0 plays at STMIK-effective tempo 120, NOT its header's
      // 125 (see tool/render_soundtrack.py); the capture's timeline maps to
      // this soundtrack as `ours = capture + 0.200s` (chroma-aligned, and the
      // boom anchor agrees: capture boom 103.890 = ours 104.090 = dis_sync cue
      // 10). Cue-derived starts come from the row-clock cue table
      // (tool/extract_music_rows.py); capture-measured starts carry the +0.20.
      entries: [
        // Black musical leader; the three cards fade in on dis_sync cues 1-3
        // (MUSIC0 orders 2:0, 3:0, 3:47 = 16.090 / 24.090 / 29.965s).
        PartEntry(0.0, CreditsPart.new, name: 'Intro Credits'),
        // dis_sync cue 4 (DIS/DISINT.ASM `ordersync1`: MUSIC0 order 4 row 47),
        // resolved through the row clock to 37.965s. The part starts its
        // 128-retrace picture fade-up HERE; that fade is why the first non-black
        // pixel only shows at ~39.5s. Do not "correct" this to the visible time.
        PartEntry(37.965, HorizonPart.new, name: 'Horizon & Ship'),
        // THE MUSIC SWITCH = dis_sync cue 10 (MUSIC0 order 13 row 0, module
        // t=104.000 -> soundtrack 104.090). PAM/OUTTAA.C waits for
        // `dis_sync()>=10`, sets the palette full white and runs wfade[]: the
        // part OPENS on a white flash, fades down through the animation, then
        // fades back to white (wfade[30..41]) and holds while the title loads.
        // The demo swaps modules here and the BOOM sounds AT the switch (the
        // capture's boom attack, 103.890, is this instant) — so the soundtrack
        // cuts MUSIC0's build-up straight into the boom at 104.090
        // (tool/render_soundtrack.py) and the flash lands on the bang.
        PartEntry(104.09, ExplosionPart.new, name: 'Praxis Explosion'),
        // wfade[] fades back to white and the part holds it while the title
        // loads; the title's white->colour fade begins at capture 106.83 →
        // 107.03 here and runs its 129 steps. A load/hold, not a music cue.
        PartEntry(107.03, TitlePart.new, name: 'Title'),
        // The checkerboard's spring reveal seeds a single row at y=130 (65% of
        // the screen) — the frame that row appears is capture 116.80 → 117.00.
        PartEntry(117.00, GlenzPart.new, name: 'Glenz & Checkerboard'),
        // The tunnel's first ring only becomes visible 20 jiffies in (a ring
        // must travel from the injection slot to ring 80 before it is drawn),
        // so the part starts before its first dots. Capture 153.15 (video
        // dot-count ramp, tool/analyze_video) → 153.35.
        PartEntry(153.35, TunnelPart.new, name: 'Dot Tunnel'),
        // The interference part opens with KOEB's 256-frame phase: the static
        // rings fade up from black, then `palfader` runs past 256 and saturates
        // every entry at 63, so the screen holds full white for its last ~95
        // frames. That white is the segment measured at capture 170.5-172.1,
        // and KOEA's mauve rings cut in the frame it ends — capture frame 0 =
        // 172.10 - 256/70 = 168.45 → 168.65 here.
        PartEntry(168.65, InterferencePart.new, name: 'Interference'),
        // KOE.C flashes the rings white, switches to the 16-colour planar mode
        // and fills page 0 white — the capture holds pure white from 186.30 →
        // 186.50 here. Everything after that rides the music ROW grid: the
        // four-column wipe waits for `(dis_musrow()&7)==7` before each strip,
        // and `waitborder()` re-latches the beat flash on that same row all the
        // way through the boxes. The part reads MusicRows directly, so nothing
        // here is a period.
        PartEntry(186.50, TechnoPart.new, name: 'Techno Boxes & Troll'),
        // PANIC (PANICEND.EXE) has NO music sync of its own — SHUTDOWN.C just
        // calls dis_partstart() and runs, so it begins the retrace the techno
        // part ends. Its first visible frame is the picture squeezed into 100
        // rows, and the capture's last full-height troll is at 225.07 with the
        // squeezed/whitened frame at 225.10 (30fps scan of 223.8-228.6), so
        // frame 0 = 225.10 + 0.20 = 225.30 here. The part then runs 192
        // retraces (squeeze 11, blank 1, eat 47, dot 60, sleep(1) 70) = 2.74s
        // and leaves black.
        PartEntry(225.30, PanicPart.new, name: 'Panic (TV Shutdown)'),
        // The forest scroller (MNTSCRL.EXE). Frame 0 is where its 64-retrace
        // leaf fade leaves black: fitting that linear fade in the capture's own
        // luma (30fps signalstats) puts it at capture 231.50 -> 231.70 here.
        // It is NOT a music cue — the original launches this part after a disk
        // load, and its two internal gates read STMIK's zone state, which the
        // vendored sources do not contain (see ForestPart). Black screen and,
        // as the capture confirms, near-silence cover the gap from panic.
        PartEntry(231.70, ForestPart.new, name: 'Forest Scroller'),
        // The lens + rotozoomer (LNS&ZOOM.EXE). Like the forest, it is gated on
        // dis_musplus, so frame 0 is measured: the fir fade's first pixels are
        // at capture 260.23 -> 260.43 here (the frame after the mode set clears
        // the screen; the forest's fade-out lands one frame before it). The two
        // phase changes inside it are LensPart.kLensAt / kZoomAt, and the code's
        // own frame counts tie them together — see LensPart.
        PartEntry(260.43, LensPart.new, name: 'Lens & Rotozoomer'),
        // PLZPART (the plasma + the plasma cube, one EXE). plz() gates on
        // dis_musplus, so frame 0 is measured — but not from a single frame:
        // the three palette drops run on dis_getmframe(), STMIK's TICK counter,
        // and MUSIC1 holds tempo 130 for the whole part (every row in the row
        // clock is 3 or 6 ticks), so a tick is exactly 1/52 s. Fitting the three
        // drops measured off the capture (320.836 / 335.560 / 342.920) against
        // PLZ.C's timetable (723 / 1491 / 1875 ticks) puts dis_setmframe(0) at
        // capture 306.894 -> 307.09 here, and reproduces all three to within
        // 0.05 s. The 127-retrace fade from white starts right at frame 0, which
        // is what picks up the white screen the rotozoomer holds.
        PartEntry(307.09, PlasmaPart.new, name: 'Plasma & Plasma Cube'),
        // MINVBALL (DOTS/). Not music-gated — MAIN.C only consults dis_musplus()
        // to break out at the very end — so frame 0 is capture-measured, and the
        // measurement is pinned twice over. The 65-step fade-in subtracts b from
        // every DAC entry while the floor ramp's brightest entry is only ~15, so
        // the floor cannot appear until b < 15: the capture's luma ramps
        // 374.53 -> 374.95 (0.42s = the last 30 of the 130 retraces) and then
        // holds, putting the main loop's frame 0 at capture 374.95 and the fade
        // (the part) 130 retraces earlier at 373.09 -> 373.29. Independently,
        // the white-out at frames 2360..2400 then falls at capture
        // 408.66..409.23, and the capture's white segment is 408.70..409.20.
        PartEntry(373.29, MiniVectorBallsPart.new, name: 'Minivectorballs'),
        // RAYSCRL (WATER/DEMO.PAS). Every gate reads STMIK state through int 0FCh
        // fn 6, so all three are capture-measured. Frame 0 is the fade-in, whose
        // 128-retrace ramp measures 410.20 -> 412.03 (1.83s = 128/70 exactly) ->
        // 410.40 here. The scroll's own start and the fade-out are
        // RayscrlPart.kScrollAt / kFadeOutAt.
        PartEntry(410.40, RayscrlPart.new, name: 'Mirror-Ball Scroll'),
        // The 3D sinusfield (COMAN/). Two clocks, both capture-measured (every
        // gate reads dis_musplus): the RETRACE clock drives `startrise`, and
        // fitting the field's rise (one row per retrace, 160 -> 0) in the capture
        // pins frame 0 to 439.43 -> 439.63 here. The RENDER clock drives the
        // camera and rotation, and the original did not manage 70 Hz: matching
        // our horizon profile against the capture's at four separate times gives
        // exactly one rendered frame per TWO retraces. See SinFieldPart.
        PartEntry(439.63, SinFieldPart.new, name: '3D Sinusfield'),
        // JPLOGO, the jellypic. Capture-measured: the scroll-in's first row is at
        // 468.42 -> 468.62 here, and its accelerating height profile matches the
        // code's own `a = 64, a += 6` CRTC ramp (83 retraces predicted, 82
        // measured). doit()'s dis_musplus() >= 4 gate has already passed by then,
        // so the jelly starts the retrace the scroll ends — as the capture shows.
        PartEntry(468.62, JpLogoPart.new, name: 'Jellypic'),
        // U2E, the city fly-through — the second VISU scene. The part TAKES OVER
        // the jellypic (it reads the DAC back and fades what is on screen up to
        // white), so its start is the first frame of that 33-retrace ramp:
        // capture 480.20 -> 480.40 here. The ramp, the hold and the second
        // 33-retrace ramp all fall exactly where U2E.C's fade block says.
        // The VECTORS themselves are on a music cue — `muscode 6` until the
        // ORDER passes 18, i.e. MUSIC0 order 19 = 483.12s — and reach the screen
        // 1.8s later, once the quad-buffered pages stop holding fadeset's white
        // (Vector2Part.kVectorsAt, measured by tracking the escort ship's orange
        // core through the capture). The stream then runs at one frame per two
        // retraces (35 fps, confirmed by the same correlation) and the part
        // whites out at 535.77.
        PartEntry(480.40, Vector2Part.new, name: 'Vector City (U2E)'),
        // The END logo (the Future Crew rings). It starts from the white the
        // fly-through's exit fade leaves behind: capture 535.83 -> 536.03 here.
        PartEntry(536.03, EndLogoPart.new, name: 'FC Logo'),
        // The credits — 21 screens at CREDITS/MAIN.C's own 361 retraces each
        // (5.157s), which is what the capture's 5.17s screen spacing shows.
        // Start measured: capture 544.33 -> 544.53.
        PartEntry(544.53, EndCreditsPart.new, name: 'Credits'),
        // The end scroller. Its start is fitted from the capture's own text
        // lattice at 760/820/890s (all three agree): capture 653.05 -> 653.25.
        // It runs to the end of the soundtrack (972.26s).
        PartEntry(653.25, EndScrollPart.new, name: 'End Scroller'),
      ],
      sync: const SyncTable([
        // U2A frame 0 — a MUSIC ROW trigger straight out of the original, not a
        // time fitted to the capture. VISU/C/U2A.C spins on `int 0FCh` fn 6
        // (DIS/DISINT.ASM `muscode_6` returns CX=order, BX=row) until
        // `order > 10 && row > 46`, i.e. MUSIC0 order 11 row 47 — 93.965s on the
        // row clock. It then plays U2A.0AB's 521 frames at one frame per VGA
        // retrace (copper 2 = the retrace int, and `currframe` advances with it),
        // so the flyover runs 521/70 = 7.44s and is over before the explosion.
        //
        // (The old 94.51 was reverse-fitted from the escorts' entry in the
        // capture, back when we replayed the U2A.PRJ keyframes. The shipped
        // U2A.0AB stream supersedes that — see IntroShipScene.)
        SyncEvent(93.965, HorizonPart.shipCode),
      ]),
      bookmarks: const [
        // The flyover is a set-piece inside the horizon part, not a part.
        Bookmark(93.9, 'Intro Ship (U2A)'),
        // The troll picture is a set-piece inside the techno part: it slides in
        // at TechnoPart.kTrollAt (31.60s local, = 218.10 here) after doit3
        // scrolls the boxes off.
        Bookmark(218.10, 'Techno Troll'),
        // The lens and the rotozoomer are two phases of one part (one EXE, as in
        // the original), so they get bookmarks rather than entries of their own.
        Bookmark(267.26, 'Lens (bouncing)'),
        Bookmark(277.55, 'Rotozoomer'),
        // The plasma and the cube are two phases of ONE part (one EXE, as in the
        // original), so they get bookmarks rather than entries of their own.
        // The cube's start is measured: capture 344.58 -> 344.78.
        Bookmark(344.78, 'Plasma Cube'),
        // The swords only start flying 9s into RAYSCRL — see RayscrlPart.
        Bookmark(419.50, 'Sword Scroll'),
      ],
    );
