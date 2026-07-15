import 'dart:math' as math;
import 'dart:typed_data';
import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/sri_image.dart';
import '../engine/vga_palette.dart';
import 'glenz_data.dart';

/// Part 5 — the glenz scene, ported at the INDEXED-FRAMEBUFFER level from
/// GLENZ/MAIN.C + VEC.ASM/NEW.ASM. Nothing is approximated:
///
///  - Background: the real FC.LBM picture with the exact ya/yy spring reveal,
///    frozen, palette-faded (frames 700-764) and wiped 2 rows/frame (765-789).
///  - Object transform: raw points, world = diag(scale*64>>15)·R·v +
///    (oxp, ypos+1500+oyp, 7500+ozp); R = rY·rX·rZ (fast angle rx on X);
///    projection sx=256x/z+160, sy=213y/z+130, z>=128 (VID.ASM).
///  - Rendering (NEW.ASM ng_pass3 + VEC.ASM demo_glz/demo_glz2): each face
///    XORs a value over the pixels it covers; the final pixel is
///    (xor-accumulator | bgpic). Visible inner faces allocate a 16-entry
///    palette block whose entries are the LIT face colour plus the background
///    colour >> 2 (a quarter-strength bleed-through); brightness is the
///    face's PROJECTED AREA (cross>>7, clamped 0..63) — camera-facing faces
///    glow, glancing faces go dark. Face colour: code bit1 ? blue
///    (B=v, G=v/2, R=7) : gray (v,v,v). Inner backfaces XOR 0/4; the outer
///    glenz XORs 0/1 (visible) and 2/4 (hidden), so over black it lands on
///    palette entries 1..7 — the finale red scheme (bit0 +10r, bit1 +30r,
///    bit2 +20r, bit3 +16 gray, from the frame-785 backpal rewrite).
class GlenzPart extends Part {
  // Scene-local seconds before the drop (physics frame 0).
  //
  // The glenz hits the floor THREE times — the NEW.ASM integrator (see
  // _physics) bounces at frames 150 / 409 / 671, i.e. 2.143 / 5.843 / 9.586s
  // after the drop, spaced 3.700 and 3.743s. MUSIC1's hits fall on a 3.692s
  // grid (= 32 rows): ... 123.251 / 126.943 / 130.635 / 134.327 ... So the
  // three bounces land on three consecutive hits on their own — the only choice
  // is WHICH hit the first one falls on, and the capture settles it: the object
  // enters at ~121.5s and first meets the floor at ~123.25s. Hence
  //   drop = 123.251 - 2.143 = 121.108s absolute = 4.108s into the part (117.00).
  // The three bounces then ring at 123.25 / 126.95 / 130.69, against hits at
  // 123.251 / 126.943 / 130.635 (drift <= 60ms, the physics' own).
  //
  // These absolutes MOVE whenever the soundtrack is recut — and they did, twice:
  // they were first measured while MUSIC1 played 5.66s early (no load silence
  // after MUSIC0, see tool/render_soundtrack.py). Re-measure against the onset
  // map, never carry the old numbers over.
  static const _dropDelay = 4.108;

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final SriImage _fc;
  final Uint8List _board = Uint8List(320 * 200); // bgpic (indexes 0..15)
  final Uint8List _xor = Uint8List(320 * 200); // face XOR accumulator

  @override
  IndexedSurface get indexed => _s;

  @override
  void init() {
    _fc = AssetStore.images['fc']!;
  }

  // ---- exact integer physics (GLENZ/MAIN.C main loop) ---------------------

  static int _sin1024(int i) =>
      (math.sin((i & 1023) * 2 * math.pi / 1024) * 256).truncate();

  ({
    int ypos,
    int xscale,
    int yscale,
    int zscale,
    int bscale,
    int oxp,
    int oyp,
    int ozp,
    int oxb,
    int oyb,
    int ozb,
  }) _physics(int frames) {
    var ypos = -9000, yposa = 0, boingm = 6, boingd = 7;
    var jello = 0, jelloa = 0;
    var xscale = 120, yscale = 120, zscale = 120, bscale = 0;
    var oxp = 0, oyp = 0, ozp = 0, oxb = 0, oyb = 0, ozb = 0;
    for (var f = 1; f <= frames; f++) {
      if (f > 900) {
        final a = f - 900;
        var b = a;
        if (b > 50) b = 50;
        oxp = _sin1024(a * 3) * b ~/ 10;
        oyp = _sin1024(a * 5) * b ~/ 10;
        ozp = (_sin1024(a * 4) ~/ 2 + 128) * b ~/ 16;
        if (f > 1800) {
          var a2 = f - 1800 + 64;
          if (a2 > 1024) a2 = 1024;
          oxb = -_sin1024(a2 * 6) * a2 ~/ 40;
          oyb = -_sin1024(a2 * 7) * a2 ~/ 40;
          ozb = (_sin1024(a2 * 8) + 128) * a2 ~/ 40;
        } else {
          oxb = -_sin1024(a * 6);
          oyb = -_sin1024(a * 7);
          ozb = _sin1024(a * 8) + 128;
        }
        var bb = 1800 - f;
        if (bb < 0) {
          if (bb < -99) bb = -99;
          oyp -= bb * bb ~/ 2;
        }
      }
      if (f > 800) {
        if (f > 1220 + 789) {
          if (xscale > 0) xscale -= 1;
          if (yscale > 0) yscale -= 1;
          if (zscale > 0) zscale -= 1;
          if (bscale > 0) bscale -= 1;
        } else {
          if (bscale < 180) {
            bscale += 2;
          } else {
            bscale = 180;
          }
        }
      } else {
        if (f < 640 + 70) {
          yposa += 31;
          ypos += yposa ~/ 40;
          if (ypos > -300) {
            ypos -= yposa ~/ 40;
            yposa = -(yposa * boingm ~/ boingd);
            boingm += 2;
            boingd += 1;
          }
          if (ypos > -900 && yposa > 0) {
            jello = (ypos + 900) * 5 ~/ 3;
            jelloa = 0;
          }
        } else {
          if (ypos > -2800) {
            ypos -= 16;
          } else if (ypos < -2800) {
            ypos += 16;
          }
        }
        yscale = xscale = 120 + jello ~/ 30;
        zscale = 120 - jello ~/ 30;
        final a = jello;
        jello += jelloa;
        if ((a < 0 && jello > 0) || (a > 0 && jello < 0)) {
          jelloa = jelloa * 5 ~/ 6;
        }
        jelloa -= jello ~/ 20;
      }
    }
    return (
      ypos: ypos,
      xscale: xscale,
      yscale: yscale,
      zscale: zscale,
      bscale: bscale,
      oxp: oxp,
      oyp: oyp,
      ozp: ozp,
      oxb: oxb,
      oyb: oyb,
      ozb: ozb,
    );
  }

  // R = rY·rX·rZ (MATH.ASM calcmatrix), rz = 0; angle unit 3600 = 360°.
  static List<double> _matrixYxz(double xu, double yu) {
    final ax = xu * math.pi / 1800, ay = yu * math.pi / 1800;
    final sx = math.sin(ax), cx = math.cos(ax);
    final sy = math.sin(ay), cy = math.cos(ay);
    return [
      cy, sx * sy, -cx * sy, //
      0, cx, sx, //
      sy, -sx * cy, cx * cy, //
    ];
  }

  // ---- per-frame render (all into the indexed surface) --------------------

  @override
  void update(double t, List<int> syncCodes) {
    // 1) Board (bgpic): exact spring reveal, then static, then wiped.
    _board.fillRange(0, _board.length, 0);
    final revealFrames = (t * kDemoFps).floor();
    var yy = 0, ya = 0;
    for (var fr = 0; fr < revealFrames; fr++) {
      ya++;
      yy += ya;
      if (yy > 48 * 16) {
        yy -= ya;
        ya = -ya * 2 ~/ 3;
        if (ya > -4 && ya < 4) break;
      }
    }
    final frame = ((t - _dropDelay) * kDemoFps).floor();
    if (revealFrames > 0) {
      final y = yy ~/ 16;
      final y1 = 130 + y ~/ 2;
      final y2 = 130 + y * 3 ~/ 2;
      if (y2 > y1) {
        final b = 25600 ~/ (y2 - y1);
        var c = 0;
        var ry = y1;
        for (; ry < y2; ry++, c += b) {
          if (ry < 0 || ry > 199) continue;
          final src = (c ~/ 256).clamp(0, 99) * _fc.width;
          _board.setRange(ry * 320, ry * 320 + 320, _fc.pixels, src);
        }
        for (var e = 0; e < 16; e++, ry++) {
          if (ry < 0 || ry > 199) continue;
          if (e <= 7) {
            final src = (100 + e) * _fc.width;
            _board.setRange(ry * 320, ry * 320 + 320, _fc.pixels, src);
          }
        }
      }
    }
    if (frame >= 765) {
      final last = math.min(199, 150 + (frame - 765) * 2 + 1);
      for (var ry = 150; ry <= last; ry++) {
        _board.fillRange(ry * 320, ry * 320 + 320, 0);
      }
    }

    // 2) Objects: XOR face values into _xor (NEW.ASM pass), building the
    //    dynamic palette blocks for visible inner faces as we go.
    _xor.fillRange(0, _xor.length, 0);
    final blocks = <int, List<int>>{}; // slot base -> [r,g,b] lit face colour
    if (frame > 0) {
      final p = _physics(frame);
      final frameD = (t - _dropDelay) * kDemoFps;
      final rx = frameD * 32, ry = frameD * 7;
      const fp = 64.0 / 32768.0;

      final lightshift = (frame > 800 && p.bscale > p.xscale) ? 10 : 9;

      // Project a raw vertex list; returns screen x/y (truncated ints).
      (List<int>, List<int>) project(List<double> verts, List<double> rot,
          double sxS, double syS, double szS, double tx, double ty, double tz) {
        final n = verts.length ~/ 3;
        final xs = List<int>.filled(n, 0), ys = List<int>.filled(n, 0);
        for (var i = 0; i < n; i++) {
          final x = verts[i * 3], y = verts[i * 3 + 1], z = verts[i * 3 + 2];
          final rxv = rot[0] * x + rot[1] * y + rot[2] * z;
          final ryv = rot[3] * x + rot[4] * y + rot[5] * z;
          final rzv = rot[6] * x + rot[7] * y + rot[8] * z;
          final wx = rxv * sxS + tx, wy = ryv * syS + ty;
          var wz = rzv * szS + tz;
          if (wz < 128) wz = 128;
          xs[i] = (256.0 * wx / wz + 160.0).truncate();
          ys[i] = (213.0 * wy / wz + 130.0).truncate();
        }
        return (xs, ys);
      }

      var nextSlot = 1; // slot bases 16,32,... (slot*16)
      void drawList(List<int> xs, List<int> ys, List<List<int>> tris,
          {required bool outer}) {
        for (final tri in tris) {
          final a = tri[0], b = tri[1], c = tri[2], code = tri[3];
          final cross = (xs[b] - xs[a]) * (ys[c] - ys[a]) -
              (ys[b] - ys[a]) * (xs[c] - xs[a]);
          // checkhidden winding: front faces are the minority set (8-11 of
          // 24), which is what fits the original's 15 palette slots.
          final visible = cross > 0;
          int value;
          if (outer) {
            // demo_glz2: visible -> (code>>1)&1; hidden -> code unchanged.
            value = visible ? (code >> 1) & 1 : code;
          } else {
            if (visible) {
              // demo_glz: allocate a palette block; entry = lit + bg>>2.
              var v = lightshift == 9
                  ? cross.abs() >> 7
                  : (cross.abs() >> 8) + (cross.abs() >> 9);
              v = v.clamp(0, 63);
              final base = (1 + ((nextSlot - 1) % 14)) * 16; // 15 slots max
              nextSlot++;
              if ((code & 2) != 0) {
                blocks[base] = [7, v >> 1, v]; // blue face (R=7,G=v/2,B=v)
              } else {
                blocks[base] = [v, v, v]; // gray face
              }
              value = base;
            } else {
              value = (code & 2) != 0 ? 4 : 0; // hidden: ((code>>1)&1)<<2
            }
          }
          if (value != 0) _xorTriangle(xs, ys, a, b, c, value);
        }
      }

      // rotlist stores its outputs in swapped order ([di+4]=row2, [di+8]=row1),
      // and the scale pass re-permutes them, so the NET effective transform is:
      //   screen_x = xscale·(R row0·v),  screen_y = ZSCALE·(R row1·v),
      //   depth    = YSCALE·(R row2·v)
      // i.e. the VERTICAL squash comes from zscale and the depth from yscale.
      // That is what makes the impact a flat pancake (zscale 93) and the
      // rebound a strictly VERTICAL stretch (no lunge toward the camera).
      // cmatrix_yxz stores C-arg rx into the roty slot: rx spins Y, ry tilts X.
      if (p.xscale > 4) {
        final rot = _matrixYxz(ry, rx);
        final (xs, ys) = project(
            glenzVerts,
            rot,
            p.xscale * fp,
            p.zscale * fp, // vertical
            p.yscale * fp, // depth
            p.oxp.toDouble(),
            p.ypos + 1500.0 + p.oyp,
            7500.0 + p.ozp);
        drawList(xs, ys, glenzTris, outer: false);
      }
      if (frame > 800 && p.bscale > 4) {
        final rot = _matrixYxz(3600 - ry / 3, 3600 - rx / 3);
        final s = p.bscale * fp;
        final (xs, ys) = project(glenzOuterVerts, rot, s, s, s,
            p.oxb.toDouble(), p.ypos + 1500.0 + p.oyb, 7500.0 + p.ozb);
        drawList(xs, ys, glenzOuterTris, outer: true);
      }
    }

    // 3) Composite: pixel = xor | board (fillmacro's `or ah,fs:[di]`).
    final px = _s.pixels;
    for (var i = 0; i < px.length; i++) {
      final x = _xor[i];
      px[i] = x == 0 ? _board[i] : (x | _board[i]);
    }

    // 4) Palette. backpal = FC colours until frame 785, then the red/gray
    //    scheme. Entries 0..15 shown = pal (faded); blocks = lit + backpal>>2.
    final fcp = _fc.palette.bytes;
    final backpal = List<int>.generate(48, (i) => fcp[i]);
    if (frame > 785) {
      for (var a = 0; a < 16; a++) {
        var r = 0, g = 0, b = 0;
        if ((a & 1) != 0) r += 10;
        if ((a & 2) != 0) r += 30;
        if ((a & 4) != 0) r += 20;
        if ((a & 8) != 0) {
          r += 16;
          g += 16;
          b += 16;
        }
        backpal[a * 3] = math.min(63, r);
        backpal[a * 3 + 1] = math.min(63, g);
        backpal[a * 3 + 2] = math.min(63, b);
      }
    }
    // Displayed entries 0..15 (`pal`): FC colours faded 700-764, black-ish
    // 765-789 (rows wiped anyway), red scheme from 790, fading out >2069.
    var palScale = 1.0;
    if (frame > 2069) {
      palScale = ((2069 + 64 - frame) / 64.0).clamp(0.0, 1.0);
    } else if (frame > 700 && frame < 790) {
      palScale = ((764 - frame) / 64.0).clamp(0.0, 1.0);
    }
    final vp = VgaPalette.black();
    for (var a = 0; a < 16; a++) {
      vp.setRgb(
          a,
          (backpal[a * 3] * palScale).round(),
          (backpal[a * 3 + 1] * palScale).round(),
          (backpal[a * 3 + 2] * palScale).round());
    }
    blocks.forEach((base, lit) {
      for (var bg = 0; bg < 16; bg++) {
        final idx = base + bg;
        if (idx > 255) continue;
        vp.setRgb(
            idx,
            math.min(63, lit[0] + (backpal[bg * 3] >> 2)),
            math.min(63, lit[1] + (backpal[bg * 3 + 1] >> 2)),
            math.min(63, lit[2] + (backpal[bg * 3 + 2] >> 2)));
      }
    });
    _s.palette = vp;
  }

  /// Scanline-XOR a triangle's coverage with [value] (half-open spans so
  /// adjacent faces tile without double-XOR, like the original edge lists).
  void _xorTriangle(List<int> xs, List<int> ys, int a, int b, int c, int value) {
    var minY = math.min(ys[a], math.min(ys[b], ys[c]));
    var maxY = math.max(ys[a], math.max(ys[b], ys[c]));
    if (maxY < 0 || minY > 199) return;
    minY = math.max(minY, 0);
    maxY = math.min(maxY, 199);
    for (var y = minY; y <= maxY; y++) {
      // Gather span from the three edges at scanline y (top-inclusive,
      // bottom-exclusive so shared vertices don't double-count).
      var xl = 1 << 30, xr = -(1 << 30);
      void edge(int i, int j) {
        var y0 = ys[i], y1 = ys[j], x0 = xs[i], x1 = xs[j];
        if (y0 == y1) return;
        if (y0 > y1) {
          final ty = y0;
          y0 = y1;
          y1 = ty;
          final tx = x0;
          x0 = x1;
          x1 = tx;
        }
        if (y < y0 || y >= y1) return;
        final x = x0 + (x1 - x0) * (y - y0) ~/ (y1 - y0);
        if (x < xl) xl = x;
        if (x > xr) xr = x;
      }

      edge(a, b);
      edge(b, c);
      edge(c, a);
      if (xl > xr) continue;
      if (xr < 0 || xl > 319) continue;
      xl = math.max(xl, 0);
      xr = math.min(xr, 319);
      final row = y * 320;
      for (var x = xl; x < xr; x++) {
        _xor[row + x] ^= value;
      }
    }
  }
}
