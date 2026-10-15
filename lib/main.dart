import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'demo_script.dart';
import 'engine/screen_wake_io.dart'
    if (dart.library.js_interop) 'engine/screen_wake_web.dart';
import 'engine/asset_store.dart';
import 'engine/demo_clock.dart';
import 'engine/audio_clock_io.dart'
    if (dart.library.js_interop) 'engine/web_audio_clock.dart';
import 'engine/commentary_panel.dart';
import 'engine/demo_timeline.dart';
import 'engine/demo_view.dart';
import 'engine/tv.dart';
import 'paused_overlay.dart';
import 'start_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Resolved before the first frame: the landing screen reads isAndroidTv while
  // building, and a TV drops the outbound link (TV-WB). One platform call.
  await initTvDetection();
  // On a phone or tablet the demo is landscape-only: the whole thing renders
  // into a 4:3 landscape field (VGA 320x200 on a 4:3 CRT), so a portrait window
  // would letterbox it into a strip. Android's manifest already pins the
  // activity; this covers iOS and any embedder that ignores the manifest.
  // Desktop and web keep a resizable window — there is nothing to rotate.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Full-bleed: no status/nav bar eating into the 4:3 field.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  runApp(const SecondRealityApp());
}

class SecondRealityApp extends StatelessWidget {
  const SecondRealityApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        // Flutter web writes this into document.title, so it must match
        // web/index.html's <title> or it silently overwrites it at startup.
        title: 'Second Reality Flutter',
        debugShowCheckedModeBanner: false,
        home: DemoScreen(),
      );
}

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});
  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> with WidgetsBindingObserver {
  DemoClock? _clock;
  DemoTimeline? _timeline;
  bool _debug = false;
  bool _framed = false; // tablet frame on/off (key T); starts off
  // Smooth upscale (key S, or the switch in the commentary panel). ON by
  // default: it is a GPU sampler flag, so it costs nothing per frame, and the
  // palette effects — glenz, tunnel, interference, the forest's warped scroll —
  // read far better filtered than as hard 320x200 blocks on a modern display.
  bool _smooth = true;
  String? _error;

  bool _starting = false;

  String? _loading; // progress text while assets/soundtrack load

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    keepScreenAwake(false); // give the screen back
    _demoFocusNode.dispose();
    super.dispose();
  }

  /// The demo is 11 minutes of watching, with no touches and no clicks — every
  /// idle timer on the machine would happily dim the screen through the middle
  /// of it. Hold the screen awake for as long as it is running, exactly as a
  /// video player does. (Wakelocks are not durable: the browser DROPS a screen
  /// wake lock whenever the tab is hidden, and Android drops it when the app
  /// goes to the background — so it has to be re-taken on resume, below.)
  void _keepScreenAwake(bool on) => keepScreenAwake(on);

  /// True while the demo is frozen because the app was backgrounded. The user
  /// has to resume it explicitly (tap, or OK on a remote) — see [PausedOverlay].
  bool _paused = false;

  /// MOBILE ONLY. On web, `inactive` fires for things as trivial as the window
  /// losing focus (clicking the dev tools), and pausing the demo every time
  /// somebody alt-tabs would be maddening — the browser already throttles a
  /// hidden tab. Backgrounding is a real, deliberate act on a phone.
  static final bool _pauseOnBackground = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_timeline == null || !_pauseOnBackground) return;

    // BACKGROUNDED: freeze the clock, not just the audio. The demo is a pure
    // function of the clock, so if the music kept playing (or the clock kept
    // running) while the app was away, we would come back to a demo that had
    // silently advanced minutes — or worse, a soundtrack playing over whatever
    // the user switched to.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      if (!_paused) {
        _clock?.pause();
        _keepScreenAwake(false); // the demo is not running: let the screen sleep
        setState(() => _paused = true);
      }
      return;
    }

    // BACK IN THE FOREGROUND. Do NOT auto-resume: the demo would restart
    // mid-scene with no warning, and on mobile the audio session may need a
    // fresh user gesture anyway. Show the overlay and let them tap.
    if (state == AppLifecycleState.resumed && !_paused) {
      _keepScreenAwake(true); // re-take the lock the system took away
    }
  }

  Future<void> _resumeDemo() async {
    await _clock?.resume();
    _keepScreenAwake(true);
    if (!mounted) return;
    setState(() => _paused = false);
    // The overlay held focus and the demo was ExcludeFocus'd behind it, so
    // nothing owns focus now. Hand it back to the demo surface once the frame
    // has made it focusable again, or a TV remote is dead after resuming.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _demoFocusNode.requestFocus());
  }

  /// Load the assets and decode the soundtrack, then start.
  ///
  /// This is plumbing, not sync: a part's `init()` needs its assets, and the
  /// WebAudio clock cannot play until `decodeAudioData` has produced the buffer.
  /// (It is NOT what keeps the demo on the music — the demo is a pure function
  /// of the clock, so a late start would cost frames, not sync. We once believed
  /// otherwise and built a whole gate around it while the real desync was a
  /// missing silence in the soundtrack.)
  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      setState(() => _loading = 'LOADING...');
      await AssetStore.loadAll();

      setState(() => _loading = 'LOADING...');
      // Web: WebAudio (hardware clock, sample-exact scheduling, instant seeks).
      // Native: audioplayers with a pre-set source.
      DemoClock clock = createDemoAudioClock('assets/music/soundtrack.ogg');
      try {
        await clock.load();
      } catch (_) {
        // decodeAudioData can't do ogg/vorbis everywhere (Safari) — fall back
        // to the element-based clock rather than dying.
        clock = AudioDemoClock('assets/music/soundtrack.ogg');
        await clock.load();
      }
      await clock.start();

      _keepScreenAwake(true); // the demo is running: no dimming, no sleeping

      setState(() {
        _loading = null;
        _clock = clock;
        _timeline = buildDemoTimeline();
      });
    } catch (e) {
      setState(() {
        _loading = null;
        _error = 'load failed: $e. click to retry';
      });
      _starting = false;
    }
  }

  /// The demo has ended (see DemoView.kDemoEnd): the scroller's last line has
  /// cleared and the music is long over. Give the screen back and return to the
  /// landing page, rather than sitting on black holding a wake lock.
  void _onDemoFinished() {
    _keepScreenAwake(false);
    _clock?.stop();
    setState(() {
      _timeline = null;
      _clock = null;
      _commentary = false;
      _showMenu = false;
      _starting = false; // START works again
    });
  }

  /// Scene jump. The buffer is already decoded, so the seek lands immediately —
  /// no overlay, no waiting.
  void _jumpTo(double seconds) => _clock?.seek(seconds);

  // Keys that honour key REPEAT (hold to nudge continuously).
  static final _repeatable = <LogicalKeyboardKey>{
    LogicalKeyboardKey.comma,
    LogicalKeyboardKey.period,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  // Debug scene-jump keys (single absolute seek).
  static final _jumpKeys = <LogicalKeyboardKey, double>{
    LogicalKeyboardKey.digit1: 15.5, // credits
    LogicalKeyboardKey.digit2: 40.0, // horizon
    LogicalKeyboardKey.digit9: 93.9, // intro ship flyover (U2A, frame 0 93.965)
    LogicalKeyboardKey.digit3: 102.5, // explosion (flash/boom at 104.09)
    LogicalKeyboardKey.digit4: 106.8, // title
    LogicalKeyboardKey.digit5: 117.2, // glenz
    LogicalKeyboardKey.digit6: 153.7, // dot tunnel
    LogicalKeyboardKey.digit7: 168.7, // interference (cyan rings -> white -> moiré)
    LogicalKeyboardKey.digit8: 186.5, // techno boxes (white wipe -> bars -> troll)
    LogicalKeyboardKey.keyP: 225.3, // panic: the TV power-off of the troll
    LogicalKeyboardKey.keyF: 231.7, // forest scroller ("another way to scroll")
    LogicalKeyboardKey.keyL: 260.5, // lens: the fir-fade reveal, then the lens
    LogicalKeyboardKey.keyR: 277.6, // rotozoomer
    LogicalKeyboardKey.keyZ: 307.1, // plasma + the plasma cube
    LogicalKeyboardKey.keyV: 373.3, // minivectorballs (the dots rain at ~375.2)
    LogicalKeyboardKey.keyW: 419.4, // the mirror-ball scroll, at the swords
    LogicalKeyboardKey.keyX: 439.7, // the 3D sinusfield, as it rises
    LogicalKeyboardKey.keyJ: 468.7, // the jellypic (scroll-in, then the wobble)
    LogicalKeyboardKey.keyU: 480.5, // U2E: the white-out, then the city
    LogicalKeyboardKey.keyG: 536.1, // the END logo (the FC rings)
    LogicalKeyboardKey.keyC: 544.6, // the credit screens
    LogicalKeyboardKey.keyE: 653.3, // the end scroller
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final c = _clock;
    if (c == null) return KeyEventResult.ignored;

    // A MODIFIED keystroke belongs to the BROWSER, never to us. Every scene-jump
    // key is a bare letter, and the demo's shortcuts collide head-on with the
    // host's: R/T/D/L/W/P are reload / new tab / bookmark / address bar / close /
    // print. Claiming one returns `handled`, which makes Flutter preventDefault()
    // the event — so ⌘R (or ctrl+R) did NOT refresh the page, it JUMPED THE DEMO
    // TO THE ROTOZOOMER (keyR = 277.6s) and swallowed the reload. Let anything
    // held with ctrl/meta/alt fall through untouched.
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }

    // The A/V nudge and the seek arrows honour key REPEAT, so they can be held
    // down (dialling in an offset 10ms at a time by tapping is miserable).
    // Toggles and scene jumps fire on the initial press only.
    final repeat = e is KeyRepeatEvent;
    if (e is! KeyDownEvent && !repeat) return KeyEventResult.ignored;
    if (repeat && !_repeatable.contains(e.logicalKey)) {
      return KeyEventResult.ignored;
    }

    // A D-PAD HAS NOTHING BUT ARROWS. This handler is an ancestor key listener,
    // so it also sees keys that bubble up from a focused button — and acting on
    // left/right there would eat the only navigation an Android TV remote has,
    // trapping focus on whatever it reached. So the demo's own keys apply only
    // while the DEMO SURFACE itself holds focus; once the viewer has D-padded
    // onto a control, the arrows belong to focus traversal and the centre button
    // to that control.
    if (!_demoFocusNode.hasPrimaryFocus) return KeyEventResult.ignored;

    // The centre of the D-pad, with the demo focused, opens and closes the
    // commentary. It is the one control a viewer gets, and on a remote there is
    // no `I` key to press.
    if (e.logicalKey == LogicalKeyboardKey.select ||
        e.logicalKey == LogicalKeyboardKey.gameButtonA) {
      setState(() => _commentary = !_commentary);
      return KeyEventResult.handled;
    }

    // ANDROID TV: the arrows are the remote's ONLY way to navigate, so they must
    // move FOCUS between the on-screen controls (the commentary panel's options
    // — close, SMOOTH PIXELS, the equaliser chevron), NOT seek. Returning
    // ignored lets the event bubble up to Flutter's default DirectionalFocusIntent
    // shortcuts, which run the focus traversal. Play's TV review requires the
    // app's options to be reachable with a D-pad; seeking trapped focus on the
    // demo and made them unreachable. On desktop the arrows still seek — there is
    // a keyboard (Tab) for traversal and a mouse for the controls.
    if (isAndroidTv &&
        (e.logicalKey == LogicalKeyboardKey.arrowLeft ||
            e.logicalKey == LogicalKeyboardKey.arrowRight ||
            e.logicalKey == LogicalKeyboardKey.arrowUp ||
            e.logicalKey == LogicalKeyboardKey.arrowDown)) {
      return KeyEventResult.ignored;
    }

    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      c.seek(c.seconds + 5);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      c.seek((c.seconds - 5).clamp(0, double.infinity));
    } else if (e.logicalKey == LogicalKeyboardKey.keyD) {
      setState(() => _debug = !_debug);
    } else if (e.logicalKey == LogicalKeyboardKey.keyT) {
      setState(() => _framed = !_framed); // toggle tablet frame
    } else if (e.logicalKey == LogicalKeyboardKey.keyI) {
      setState(() => _commentary = !_commentary); // the (i) commentary track
    } else if (e.logicalKey == LogicalKeyboardKey.keyS) {
      setState(() => _smooth = !_smooth); // smooth the upscale (GPU sampler)
    } else if (e.logicalKey == LogicalKeyboardKey.comma) {
      // A/V offset, on , and . (unshifted on every layout — [ and ] are dead or
      // shifted keys on many, and Flutter web reports them inconsistently).
      // What a player REPORTS as its position is not what you HEAR (output
      // buffer) nor what you SEE (compositor). Dial it in by ear on a
      // music-locked part — the explosion's flash, or the glenz impacts — then
      // bake the value into DemoClock.defaultAvOffset. 0 resets.
      setState(() => c.avOffset -= 0.010); // visuals LATER (t lags the audio)
    } else if (e.logicalKey == LogicalKeyboardKey.period) {
      setState(() => c.avOffset += 0.010); // visuals EARLIER (t runs ahead)
    } else if (e.logicalKey == LogicalKeyboardKey.digit0) {
      setState(() => c.avOffset = 0);
    } else if (_jumpKeys.containsKey(e.logicalKey)) {
      // Scene jump: through the load-and-init gate, never a bare seek.
      _jumpTo(_jumpKeys[e.logicalKey]!);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        // A key listener for the demo's DESKTOP keyboard shortcuts only — it
        // must NEVER hold focus itself. As an autofocusing focus stop it STOLE
        // focus from the landing screen's START button (confirmed: primaryFocus
        // landed on THIS node, not the FocusableActionDetector), so a TV
        // remote's centre press reached this handler — which ignores everything
        // until the demo has started — instead of activating START. The app
        // could not be started with a D-pad at all, which is exactly what Play's
        // TV review flagged. canRequestFocus:false makes it a pure ANCESTOR key
        // listener: START (landing) and the demo surface (running) own the
        // focus, and their key events still bubble up through here for the
        // desktop shortcuts.
        canRequestFocus: false,
        onKeyEvent: _onKey,
        child: _timeline == null ? _startScreen() : _demo(),
      ),
    );
  }

  /// The demo surface's own focus node. It is what holds focus while the demo
  /// is running (autofocused when the demo starts), so the demo's own keys apply
  /// only while IT is focused — once the viewer has D-padded onto a panel
  /// control, that control owns the input. On a TV this node is also the anchor
  /// the D-pad traverses OUT of, into the commentary panel's controls.
  final FocusNode _demoFocusNode = FocusNode(debugLabel: 'demoSurface');

  bool _showMenu = false;
  // The (i) documentary track, OPEN by default. The demo is 16 minutes of
  // effects whose whole point is invisible without the commentary, and a viewer
  // who does not know the panel exists never presses (i). Opening it makes the
  // offer once; closing it is one click and it stays closed.
  bool _commentary = true;

  /// Lets the key handler reach the view (for the B calibration flash).
  final GlobalKey<DemoViewState> _demoKey = GlobalKey<DemoViewState>();

  Widget _demo() {
    // With the commentary open the demo gives up the space the panel takes,
    // rather than being covered by it. The panel is ALWAYS a right-hand column
    // (it never wraps to a band under the demo), so the demo is simply inset by
    // the panel's own width. The demo is a pure function of the clock, so losing
    // width costs it frames of nothing: it just renders smaller.
    // The demo surface is a focus stop, autofocused when the demo starts, so
    // there is always a "home" for the D-pad and a rect the remote can traverse
    // OUT of into the panel's controls. Its node is what _onKey gates on.
    final demo = Focus(
      focusNode: _demoFocusNode,
      autofocus: true,
      child: DemoView(
          key: _demoKey,
          timeline: _timeline!,
          clock: _clock!,
          debugOverlay: _debug,
          framed: _framed,
          smooth: _smooth,
          onFinished: _onDemoFinished),
    );

    return Stack(
      children: [
        // While paused, NOTHING behind the overlay may take focus: a Stack layer
        // does not trap focus the way a dialog route does, and the remote would
        // otherwise reach the demo surface and the panel's controls under it.
        Positioned.fill(
          child: ExcludeFocus(
            excluding: _paused,
            child: _demoLayers(demo),
          ),
        ),
        if (_paused)
          Positioned.fill(
            child: PausedOverlay(onResume: _resumeDemo, remote: isAndroidTv),
          ),
      ],
    );
  }

  Widget _demoLayers(Widget demo) {
    return Stack(
      children: [
        if (!_commentary)
          demo
        else
          Padding(
            padding:
                EdgeInsets.only(right: CommentaryPanel.widthFor(context)),
            child: demo,
          ),
        if (_commentary)
          CommentaryPanel(
            clock: _clock!,
            timeline: _timeline!,
            onClose: () => setState(() => _commentary = false),
            // The one PICTURE control a viewer gets, next to the one they
            // already have. Same state the S key drives, so the two agree.
            smooth: _smooth,
            onSmoothChanged: (v) => setState(() => _smooth = v),
          ),
        // The (i) is the ONE control a viewer gets. It turns the demo into a
        // documentary: what each part is, how it was done in 1993, and what it
        // cost to bring back.
        if (!_commentary)
          Positioned(
            top: 8,
            right: 8,
            child: _RoundButton(
              icon: Icons.info_outline,
              onTap: () => setState(() => _commentary = true),
            ),
          ),
        // The scene menu is a DEV tool, so it lives behind the debug HUD (key D)
        // like every other one. A viewer watching the demo should see the demo,
        // not a hamburger floating over the Future Crew logo.
        if (_debug)
          Positioned(
            top: 8,
            right: _commentary ? 8 : 56,
            child: _RoundButton(
              icon: _showMenu ? Icons.close : Icons.menu,
              onTap: () => setState(() => _showMenu = !_showMenu),
            ),
          ),
        if (_debug && _showMenu)
          Positioned(top: 52, right: 8, child: _sceneMenu()),
      ],
    );
  }

  Widget _sceneMenu() {
    final entries = _timeline!.entries;
    // Parts are numbered; bookmarks (set-pieces inside a part, like the ship
    // flyover) are listed under the part they belong to, indented and unnumbered.
    final items = <({double start, String label, bool sub})>[];
    for (var i = 0; i < entries.length; i++) {
      items.add((
        start: entries[i].start,
        label: '${i + 1}. ${entries[i].name}',
        sub: false
      ));
      for (final b in _timeline!.bookmarks) {
        final next =
            i + 1 < entries.length ? entries[i + 1].start : double.infinity;
        if (b.start >= entries[i].start && b.start < next) {
          items.add((start: b.start, label: b.name, sub: true));
        }
      }
    }
    // The list is longer than the screen once enough parts are wired in, so it
    // has to be bounded and scrollable — an unbounded Column simply runs off
    // the bottom and the last scenes become unreachable. 52 is the menu's top
    // inset (below the button), 12 leaves it clear of the bottom edge.
    final maxHeight = MediaQuery.sizeOf(context).height - 52 - 12;
    return Container(
      constraints: BoxConstraints(maxWidth: 260, maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: const Color(0xE6101018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              InkWell(
                onTap: () {
                  setState(() => _showMenu = false);
                  _jumpTo(item.start); // exact music position, gated
                },
                child: Padding(
                  padding: EdgeInsets.only(
                      left: item.sub ? 30 : 14,
                      right: 14,
                      top: item.sub ? 6 : 9,
                      bottom: item.sub ? 6 : 9),
                  child: Text(
                    item.sub ? '↳ ${item.label}' : item.label,
                    style: TextStyle(
                        color: item.sub
                            ? const Color(0xFF9AA0B0)
                            : const Color(0xFFDDDDE6),
                        fontSize: item.sub ? 13 : 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // The build stamp lives in the debug HUD (D) only — it is a developer tool (a
  // stale one means the browser is serving a cached build and NOTHING you
  // observe means anything), not part of the title screen.
  Widget _startScreen() =>
      StartScreen(onStart: _start, loading: _loading, error: _error);
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xB3101018),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: const Color(0xFFDDDDE6), size: 22),
        ),
      ),
    );
  }
}
