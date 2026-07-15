/// The live commentary track: the demo as a documentary.
///
/// SOURCE OF TRUTH. `reference/commentary.md` is generated from this file by
/// `tool/dump_commentary.py`, so the review doc cannot drift from what ships.
///
/// Every technical number here is MEASURED from this repo (meshes parsed out of
/// the .srv scenes, LOC counted, timings taken from demo_script.dart). Every
/// historical claim was checked against Wikipedia (Second Reality, Future Crew,
/// Scream Tracker, Remedy), the 2013 source release, and Fabien Sanglard's code
/// review. Three claims in the first draft were wrong and were corrected: Scream
/// Tracker is the work of ONE member (Sami Tammilehto), the "4MB RAM" figure has
/// no source and is gone, and the source release is July 2013.
///
/// The spine of the script is a single idea: the demo is not computing what you
/// see, it is LOOKING IT UP. Refraction, occlusion, camera paths, bounce physics
/// and even the water were all baked offline in 1993, and the CPU's job at run
/// time is mostly to copy memory.
///
/// IT MUST BE READABLE, AND THAT IS A HARD BUDGET, NOT A STYLE NOTE. A card is
/// the current card until the next one appends, and many viewers do not read
/// English natively, so `tool/check_commentary_timing.py` holds every card to
/// 130 words per minute of its own dwell. The whole script therefore cannot
/// exceed the demo's run time at that rate: it is a fixed pot of about 2,100
/// words, and a sentence added here is a sentence taken from somewhere else.
///
/// TWO RULES FOLLOW, AND THEY EXPLAIN THE LAYOUT BELOW.
///   * An EFFECT card sits on its effect (about 1.2s after the part's start in
///     demo_script.dart) and cannot move. Where a part gives it no room -- the
///     glenz has 4.3s before its bounce lands, the explosion 2.9s before the
///     title -- the cards are MERGED rather than raced past the reader.
///   * A BACKGROUND card (the history, the port, what it cost) explains nothing
///     on screen, so it goes where there IS room. The intro is the most crowded
///     stretch in the demo and used to carry eleven cards in 118 seconds, which
///     no one could keep up with; the end scroller runs for five minutes with
///     nothing to explain. The history now lives there.
library;

/// One commentary card. [time] is a music position in seconds, the same clock
/// every part uses, so the commentary cannot drift from the demo either.
class CommentaryCard {
  final double time;
  final String title;
  final String body;
  const CommentaryCard(this.time, this.title, this.body);
}

/// The cards, in time order.
const List<CommentaryCard> kCommentary = [
  // --- ACT 0: the intro. Only what explains what is on screen. -------------
  CommentaryCard(
    0.0,
    'What you are watching',
    'Second Reality won the PC demo competition at Assembly, in Finland, in '
        'July 1993. No video is being played: every frame is computed live.'
        '\n\n'
        'Ported to Flutter by the people behind **primio.dev**',
  ),
  CommentaryCard(
    15.0,
    'Future Crew',
    'A Finnish group of about a dozen people. One of them, Sami Tammilehto, '
        'wrote Scream Tracker, and with it the .S3M music format. The music you '
        'are hearing is two .S3M files.',
  ),
  CommentaryCard(
    30.0,
    'The machine',
    'A 486, VGA, no GPU, and no floating point worth using. Nearly all of this '
        'is fixed-point integer math, on a chip about a thousandth as fast as '
        'the phone in your pocket.',
  ),
  CommentaryCard(
    45.0,
    'The trick behind every trick',
    'So how do you do 3D, refraction and plasma on that? You do not. You '
        'precompute. These programs are mostly TABLES, baked offline and '
        'replayed. The CPU mainly copies memory.',
  ),
  CommentaryCard(
    60.0,
    'The source',
    'Future Crew released the code in 2013, into the public domain: 37,758 '
        'lines of assembly, 27,798 of C, and 2,118 of Pascal, because one '
        'author preferred Pascal. Each part is its own program.',
  ),
  CommentaryCard(
    75.0,
    'The music is the clock',
    'It does not sync to seconds. It syncs to the row counter inside the music '
        'file, so the visuals cannot drift. The original played this tune four '
        'percent slower than its own file claims, which put every visual '
        'seconds behind the melody.',
  ),
  CommentaryCard(
    95.0,
    'The ship',
    'Three meshes, 489 vertices, and not animated by code. It is a recorded '
        'stream of 521 frames.',
  ),

  // --- ACT 1: the parts ----------------------------------------------------
  CommentaryCard(
    105.0,
    'The boom',
    'It holds white while the next part loads off disk, and the load is '
        'audible: the music stops for 1.7 seconds. Not a bug. We put it back.',
  ),
  CommentaryCard(
    118.2,
    'The glenz, and a bassline',
    'Glenz is scene slang: convex polygons XOR-blended, so overlaps invert. Not '
        'transparency, just arithmetic the hardware did for free. It hits the '
        'floor three times, 3.70 seconds apart; the music hits every 3.69. They '
        'tuned the gravity to land on the beat.',
  ),
  CommentaryCard(
    138.0,
    'One tick = one retrace',
    'Fades here run one step per vertical retrace. That is the demo\'s unit of '
        'time: not milliseconds, but the 70 Hz tick of the electron beam '
        'finishing the screen and flying back to the top.',
  ),
  CommentaryCard(
    154.5,
    'The tunnel, in Pascal',
    'Written in Turbo Pascal, and it is a table again: the dot positions come '
        'from a file generated once. Our bug porting it was Pascal\'s banker\'s '
        'rounding, where 42.5 rounds to 42.',
  ),
  CommentaryCard(
    169.8,
    'Interference',
    'Two ring bitmaps slide across each other, and the moire is real '
        'interference. But the violence of it is a palette trick: the overlay '
        'picks between two colour banks, and that flip is what your eye reads '
        'as the pattern detonating.',
  ),
  CommentaryCard(
    187.7,
    'We ported the chip',
    'Porting the drawing here was hopeless, so we ported the VGA instead: '
        'planar memory, four bit-planes, eight pages, the CRTC registers. The '
        'page flipping and the scroll-off then simply happen, including the '
        'ghost trails, which nobody drew.',
  ),
  CommentaryCard(
    205.0,
    'Trails are a memory layout',
    'Each frame writes into ONE plane of ONE page, so a page\'s four planes are '
        'eight frames apart in time. A pixel\'s colour is literally how many of '
        'the last four passes covered it. The motion blur is an artefact of '
        'where the bits live.',
  ),
  CommentaryCard(
    226.5,
    'The TV switch-off',
    'This part loads no picture. It reads the palette back out of the hardware '
        'and destroys whatever the last part left on screen.',
  ),
  CommentaryCard(
    238.0,
    'Another way to scroll',
    'Nothing is projected or masked at run time. Precomputed tables map each '
        'cell of the font to the pixels it lights, and the warp AND the '
        'occlusion are baked in: a letter behind a leaf is simply ABSENT from '
        'the table. The text brightens the picture, it does not overwrite it.',
  ),
  CommentaryCard(
    261.6,
    'The lens is a memory copy',
    'The refraction is not computed. A program run once by the authors baked it '
        'into lists of source and destination offsets, so the bulge is a memory '
        'copy. Even the bounce is a replay.',
  ),
  CommentaryCard(
    278.7,
    'The rotozoomer',
    'There is no trigonometry per pixel: you walk the texture with two '
        'fixed-point deltas, so a pixel costs an addition. Note the pentagram '
        'on his forehead. The art in the source tree is older, and has none.',
  ),
  CommentaryCard(
    295.0,
    'The pictures are new',
    'Five backdrops were redrawn with an image model, then quantised back into '
        'the demo\'s own indexed VGA format. The code cannot tell.',
  ),
  CommentaryCard(
    308.3,
    'Plasma, the classic',
    'The effect every scener wrote first: sum a few sines, use the result as a '
        'palette index, then animate the PALETTE instead of the pixels.',
  ),
  CommentaryCard(
    322.0,
    'It is not falling',
    'The plasma is 280 rows tall, and the split between it and the black band '
        'is one hardware register. To drop it off the screen, the original '
        'walks that split down a gravity curve. The picture is not moving, the '
        'register is. It is also drawn twice per frame, swapped every retrace.',
  ),
  CommentaryCard(
    346.0,
    'The cube is a spline',
    'Position, distance, rotation and light are eight channels of a spline over '
        '136 control points. Nothing about this cube is hand-animated, and its '
        'faces are plasma textures displaced through a scrolling sine. The '
        'ripple is a lookup, not a shader.',
  ),
  CommentaryCard(
    374.5,
    '512 balls',
    'One ball respawns every retrace onto a Lissajous figure, gets 16-bit '
        'gravity, and keeps thirteen-sixteenths of its speed on each bounce. '
        'The floor is not geometry: it is a hundred rows of colour ramp.',
  ),
  CommentaryCard(
    390.0,
    'Never guess',
    'The rule for this port was that nothing may be eyeballed. Every position, '
        'duration and colour comes from the original source or data. Every '
        'scene rebuilt by eye, because it looked close enough, turned out to be '
        'wrong.',
  ),
  CommentaryCard(
    411.6,
    'Raytraced, in 1993',
    'The scroller is a sword, riding on water, and neither is rendered here. '
        'The authors ray-traced the water ONCE, offline, then read the scroll\'s '
        'texture coordinates straight out of the RED channel of that render. '
        'The ripple, the perspective and the occlusion behind the mirror balls '
        'are all baked into a table. What runs at 70 fps is a memory copy.',
  ),
  CommentaryCard(
    440.8,
    'One ray per column',
    'A voxel raycaster over a heightfield, 192 steps per column. Two carry bits '
        'matter. Drop the one on the ray\'s slope and the sky disappears.',
  ),
  CommentaryCard(
    455.0,
    'The demoscene',
    'It grew out of software cracking in the 1980s. Crackers signed their work '
        'with a little intro, the intros got competitive, and eventually the '
        'intro ate the software.',
  ),
  CommentaryCard(
    469.8,
    'The jelly is precomputed too',
    'The wobble cannot drift, because it is not simulated: 200 keyframes of the '
        'bouncing edge, interpolated into a table, one entry per retrace.',
  ),
  CommentaryCard(
    481.6,
    'The city',
    '42 meshes, 987 faces, and a recorded 1,801-frame camera. The same engine '
        'as the intro ship, thirty times the scene. It runs at 35 frames a '
        'second, not 70, because it was too heavy to draw every retrace.',
  ),
  CommentaryCard(
    500.0,
    'Watch it fly through a wall',
    'Buildings switch OFF as the camera reaches them. Not a distance cull: a '
        'shot list, because the camera flies straight THROUGH them. Force them '
        'on and the lens fills with the wall you are inside.',
  ),
  CommentaryCard(
    517.0,
    'The bug that cost the most',
    'A token carries only the low four bits of an object\'s number; the high '
        'bits carry over from an earlier token. Our extractor reset them. The '
        'ship has four objects, so the bug was invisible. The city has 58.',
  ),
  CommentaryCard(
    537.2,
    'Back to the beginning',
    'The intro tune again: the demo has two modules, and returns to the first '
        'to end.',
  ),
  CommentaryCard(
    545.7,
    'The credits are hardware',
    'Nothing is redrawn per frame. The picture is drawn once, off the right '
        'edge of memory, and the text once above it, and then two CRTC '
        'registers walk them into view. 21 screens, and the CPU is asleep.',
  ),
  CommentaryCard(
    566.0,
    'Our thumbnails',
    'The little pictures beside each credit are ours, not Future Crew\'s: '
        'screenshots of THIS port, taken by a renderer running inside the test '
        'harness. The original\'s own thumbnail for the ship part was never '
        'finished. It is a hand-scrawled note reading "PARTPIC MISSING".',
  ),
  CommentaryCard(
    588.0,
    'How we knew when it was wrong',
    'Chasing a five-second desync, we rewrote the clock twice and purged every '
        'cache before finding the cause in the soundtrack: the 1.7-second '
        'silence where the original stopped to load, which we had cut out. The '
        'lesson is an order. Prove the build is the one running. Prove the '
        'clock against its own audio. Only then suspect the data.',
  ),
  CommentaryCard(
    616.0,
    'A periodic grid cannot place itself',
    'The music hits every 3.692 seconds, so locking an effect to "a bass thud" '
        'has infinitely many answers, all plausible, all but one wrong. Only '
        'the picture picks the right bar. The glenz hits the floor at 123.25 in '
        'the capture, so it is dropped at 121.108, and the rest follows.',
  ),

  // --- ACT 2: the end scroller. Five minutes, nothing to explain, so the ---
  // background that used to crowd the intro lives here instead.
  CommentaryCard(
    654.5,
    'The last scroller',
    'This text is the one that shipped, out of a data file. The copy in the '
        'source tree is an older build, with the joke text hard-coded. The '
        'music keeps playing for five more minutes after the demo has, '
        'technically, ended.',
  ),
  CommentaryCard(
    675.0,
    'What it cost',
    'The original: 37,758 lines of assembly, 27,798 of C, 2,118 of Pascal, and '
        'roughly 83,500 lines of pure precomputed DATA. Tables of sines, '
        'gradients, orderings and paths, because a lookup was always cheaper '
        'than a thought. That ratio is the whole demoscene in one number.',
  ),
  CommentaryCard(
    700.0,
    'This port',
    'What you are watching is a Flutter app: 9,590 lines of Dart, and 6,335 of '
        'Python that exist only to prise the data back out of the 33-year-old '
        'files. Not an emulator, and not a video. The logic and the data were '
        'ported, and re-rendered.',
  ),
  // Everything from here to the end was WEB-SEARCHED, not recalled, and the
  // things that could not be sourced were left out: Assembly's attendance (the
  // big numbers come from promotional copy), and any claim that the demoscene
  // is on UNESCO's INTERNATIONAL list. It is not. Eight countries list it on
  // their own NATIONAL inventories of intangible heritage, which is the true
  // and still remarkable version.
  CommentaryCard(
    725.0,
    'Where they went',
    'Members of Future Crew founded Remedy in 1995: Max Payne, Alan Wake, '
        'Control. Four members of the Amiga group The Silents founded DICE in '
        '1992. Starbreeze grew out of the group Triton, and Housemarque out of '
        'two Finnish studios with the same roots. The scene was a training '
        'ground that produced a games industry.',
  ),
  CommentaryCard(
    750.0,
    'The other groups',
    'Farbrausch, in Germany, fitted an eleven-minute 3D demo into 64 kilobytes '
        'by generating its textures and its synthesiser as it ran. An offshoot '
        'of theirs then shipped a first-person shooter, with levels, in 96 '
        'kilobytes.',
  ),
  CommentaryCard(
    775.0,
    'Four kilobytes',
    'That became the discipline: 64 kilobytes, then four, then one, then 256 '
        'bytes. In 2009 a four-kilobyte demo called Elevated flew a camera over '
        'a raymarched mountain range, with music. Nothing in it is stored. It '
        'is all generated, on the spot.',
  ),
  CommentaryCard(
    800.0,
    'The scene today',
    'It never stopped. Revision, at Easter in Germany, is the biggest '
        'demoscene party in the world, at around eight hundred people, and '
        'Assembly still runs every summer in Helsinki. There is now a live '
        'event where two coders write a shader from scratch on stage, in 25 '
        'minutes, while the audience votes.',
  ),
  CommentaryCard(
    828.0,
    'It is heritage now',
    'Eight countries list the demoscene on their national inventories of '
        'intangible cultural heritage. Finland was first, in 2020, and it was '
        'the first digital culture ever admitted to such a list. Germany '
        'followed, then Poland, Switzerland, the Netherlands, Sweden, France '
        'and Norway.',
  ),
  CommentaryCard(
    855.0,
    'The constraint was the point',
    'None of this was done because it was elegant. It was done because the '
        'machine could not do it any other way, and the only way through was to '
        'know the hardware better than the hardware knew itself. Give those '
        'people a GPU and they would have written something else. The limit is '
        'what made the art. It still is: nothing forces a demo into four '
        'kilobytes now except the people writing it.',
  ),
  CommentaryCard(
    895.0,
    'Read it yourself',
    'Second Reality won Assembly 1993 and then would not go away; Slashdot put '
        'it on a list of the ten greatest hacks ever made. The original is '
        'public domain, at github.com/mtuomi/SecondReality, and Fabien Sanglard '
        'wrote a code review of it that is worth your evening. Everything said here '
        'is checkable against it, which is the only reason it was worth '
        'saying.',
  ),
  CommentaryCard(
    935.0,
    'Fin',
    'Future Crew, 1993. Code by Psi, Trug and Wildfire. Music by Purple Motion '
        'and Skaven. Graphics by Pixel. Thirty-three years later it still runs, '
        'because someone wrote down exactly how.',
  ),
];
