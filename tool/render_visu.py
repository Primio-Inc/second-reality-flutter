#!/usr/bin/env python3
"""Offline reference rasteriser for a VISU scene — an exact replica of the
original engine's math, used to validate the Dart port WITHOUT the slow
build-web + browser-screenshot loop.

It reproduces, in order:
  U2A.C           per frame: apply the camera matrix to every switched-on
                  object, z-sort the objects, draw them back to front.
  ACALC.ASM       calc_applyrmatrix / calc_rotate / calc_nrotate /
                  calc_project / calc_singlez  (Q18.14 fixed point, UNIT=16384)
  AVID.ASM        vid_window / vid_cameraangle  (projmulx/projmuly via the
                  _avistan cotangent table, projaspect=225 for the VGA pixel)
  ADRAW.ASM       backface culling (dot(normal, vertex) >= 0 -> hidden),
                  the hardcoded light (12118,10603,3030), the shade ramp
                  (brightness>>3/4/5 for SHADE32/16/8, clamped 1..30) and the
                  final palette index = face.color + shade.

Usage:
  python3 tool/render_visu.py assets/meshes/u2a.srv <frame> out.png
  python3 tool/render_visu.py assets/meshes/u2a.srv --montage out.png
"""
import struct
import sys
from pathlib import Path

UNIT = 16384
UNITSHR = 14
LIGHT = (12118, 10603, 3030)          # ADRAW.ASM:20 `newlight`
PROJASPECT = 225                       # AVIDM1.ASM — VGA non-square pixel

# vid_window(0,319,25,174,512,9999999) as called by U2A.C:247
CLIPX = (0, 319)
CLIPY = (25, 174)
CLIPZ = (512, 9999999)
ADDX = (CLIPX[0] + CLIPX[1]) >> 1      # 159
ADDY = (CLIPY[0] + CLIPY[1]) >> 1      # 99

F_2SIDE = 0x200
F_SHADE32 = 0xC00
F_GOURAUD = 0x1000


def load_avistan(path=Path("original/VISU/AVISTAN.INC")):
    vals = []
    for line in path.read_text().splitlines():
        line = line.split(";")[0].strip()
        if not line.lower().startswith("dw"):
            continue
        vals += [int(v) for v in line[2:].split(",") if v.strip()]
    return vals


AVISTAN = load_avistan()


def camera_angle(fov):
    """AVID.ASM:vid_cameraangle -> (projmulx, projmuly)."""
    halfwidth = CLIPX[1] - ADDX               # 160
    ha = fov >> 1
    ha = max(512, min(16383, ha))
    idx = (ha >> 5) & ~1
    t = AVISTAN[idx]
    mulx = (halfwidth * t) >> 8
    muly = (mulx * PROJASPECT) >> 8
    return mulx, muly


def sar(v, n):
    """Arithmetic shift right (Python's >> already floors, matching sar)."""
    return v >> n


def mat_mul(a, b):
    """3x3 row-major fixed-point product: (a*b)>>14  (ACALC.ASM:mulmacro)."""
    out = [0] * 9
    for r in range(3):
        for c in range(3):
            s = (a[r * 3 + 0] * b[0 * 3 + c] +
                 a[r * 3 + 1] * b[1 * 3 + c] +
                 a[r * 3 + 2] * b[2 * 3 + c])
            out[r * 3 + c] = sar(s, UNITSHR)
    return out


def rot_point(m, x, y, z):
    return (sar(m[0] * x + m[1] * y + m[2] * z, UNITSHR),
            sar(m[3] * x + m[4] * y + m[5] * z, UNITSHR),
            sar(m[6] * x + m[7] * y + m[8] * z, UNITSHR))


def apply_rmatrix(dest, cam):
    """ACALC.ASM:calc_applyrmatrix — dest := cam o dest."""
    m = mat_mul(cam["m"], dest["m"])
    px, py, pz = rot_point(cam["m"], dest["x"], dest["y"], dest["z"])
    return {"m": m, "x": px + cam["x"], "y": py + cam["y"], "z": pz + cam["z"]}


def shade_of(flags, nx, ny, nz):
    """ADRAW.ASM:normallight + calclight."""
    dot = nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]
    bright = sar(dot, 21) + 128
    bright = max(0, min(255, bright))
    mask = flags & F_SHADE32
    if mask == 0:
        return 1
    sh = bright >> (6 - (mask >> 10))
    return max(1, min(30, sh))


# ---- .srv ------------------------------------------------------------------
def load_srv(path):
    d = Path(path).read_bytes()
    assert d[:4] == b"SRV1"
    p = 4
    objn, meshn = d[p], d[p + 1]
    p += 2
    objmesh = [(-1 if d[p + i] == 255 else d[p + i]) for i in range(objn)]
    p += objn
    pal = d[p:p + 768]
    p += 768
    meshes = []
    for _ in range(meshn):
        nl = d[p]
        p += 1
        name = d[p:p + nl].decode("latin1")
        p += nl
        vn = struct.unpack_from("<H", d, p)[0]
        p += 2
        verts = [struct.unpack_from("<iii", d, p + k * 12) for k in range(vn)]
        p += vn * 12
        # Each vertex names its OWN normal (vlist.normal) — the gouraud normals.
        vertnorms = list(struct.unpack_from("<" + "H" * vn, d, p))
        p += vn * 2
        nn, n1 = struct.unpack_from("<HH", d, p)
        p += 4
        norms = [struct.unpack_from("<hhh", d, p + k * 6) for k in range(nn)]
        p += nn * 6
        pn = struct.unpack_from("<H", d, p)[0]
        p += 2
        polys = []
        for _ in range(pn):
            sides, flags, color, normal = struct.unpack_from("<BBBH", d, p)
            p += 5
            vs = struct.unpack_from("<" + "H" * sides, d, p)
            p += 2 * sides
            polys.append({"flags": flags, "color": color, "normal": normal,
                          "verts": list(vs)})
        center, ordn = struct.unpack_from("<HB", d, p)
        p += 3
        orders = []
        for _ in range(ordn):
            ref, cnt = struct.unpack_from("<HH", d, p)
            p += 4
            orders.append({"ref": ref,
                           "polys": list(struct.unpack_from(
                               "<" + "H" * cnt, d, p))})
            p += 2 * cnt
        meshes.append({"name": name.replace('"', ''), "verts": verts,
                       "vertnorms": vertnorms,
                       "norms": norms, "nnum1": n1, "polys": polys,
                       "center": center, "orders": orders})
    fn = struct.unpack_from("<H", d, p)[0]
    p += 2
    frames = []
    for _ in range(fn):
        fov = struct.unpack_from("<H", d, p)[0]
        p += 2
        objs = []
        for _ in range(objn):
            on = d[p]
            p += 1
            m = list(struct.unpack_from("<9i", d, p))
            p += 36
            x, y, z = struct.unpack_from("<iii", d, p)
            p += 12
            objs.append({"on": on, "m": m, "x": x, "y": y, "z": z})
        frames.append({"fov": fov, "objs": objs})
    return {"pal": pal, "meshes": meshes, "objmesh": objmesh, "frames": frames}


# ---- rasteriser (scanline fill of a convex polygon) -------------------------
def fill_poly(img, zbuf_unused, pts, color):
    W, H = 320, 200
    ys = [p[1] for p in pts]
    y0, y1 = max(0, min(ys)), min(H - 1, max(ys))
    n = len(pts)
    for y in range(y0, y1 + 1):
        xs = []
        for i in range(n):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            if ay == by:
                continue
            if min(ay, by) <= y < max(ay, by):
                t = (y - ay) / (by - ay)
                xs.append(ax + (bx - ax) * t)
        if len(xs) < 2:
            continue
        xa, xb = int(min(xs)), int(max(xs))
        for x in range(max(0, xa), min(W - 1, xb) + 1):
            img[y * W + x] = color


def render(scene, fi):
    W, H = 320, 200
    img = [0] * (W * H)
    fr = scene["frames"][fi]
    mulx, muly = camera_angle(fr["fov"])
    cam = fr["objs"][0]

    # U2A.C: apply the camera to every enabled object, then z-sort by the
    # object's center vertex (calc_singlez), far first.
    draw = []
    for oi in range(1, len(scene["objmesh"])):
        if not fr["objs"][oi]["on"]:
            continue
        mesh = scene["meshes"][scene["objmesh"][oi]]
        r = apply_rmatrix(fr["objs"][oi], cam)
        cv = mesh["verts"][mesh["center"]]
        dist = (sar(r["m"][6] * cv[0] + r["m"][7] * cv[1] + r["m"][8] * cv[2],
                    UNITSHR) + r["z"])
        # U2E.C's two draw-order overrides (inert for U2A, which has neither an
        # object named `_*` nor 900+ frames): the ground plates always sort to
        # the back, and for stream frames 900..1100 the ship sorts to the front.
        name = mesh["name"].replace('"', "")
        if name.startswith("_"):
            dist = 1000000000
        elif 900 < fi < 1100 and name.startswith("s01"):
            dist = 1
        draw.append((dist, oi, mesh, r))
    draw.sort(key=lambda t: -t[0])          # farthest first

    for dist, oi, mesh, r in draw:
        # calc_rotate / calc_nrotate / calc_project
        vs = [(sar(r["m"][0] * v[0] + r["m"][1] * v[1] + r["m"][2] * v[2],
                   UNITSHR) + r["x"],
               sar(r["m"][3] * v[0] + r["m"][4] * v[1] + r["m"][5] * v[2],
                   UNITSHR) + r["y"],
               sar(r["m"][6] * v[0] + r["m"][7] * v[1] + r["m"][8] * v[2],
                   UNITSHR) + r["z"]) for v in mesh["verts"]]
        ns = [rot_point(r["m"], *n) for n in mesh["norms"]]
        pv = []
        for (x, y, z) in vs:
            zz = z if z >= CLIPZ[0] else CLIPZ[0]
            pv.append(((x * mulx) // zz + ADDX, (y * muly) // zz + ADDY))

        # vis_drawobject: of the 8 direction-sorted lists, take the one whose
        # reference vertex is nearest the camera.
        best, bz = None, 0x7fffffff
        for od in mesh["orders"]:
            z = vs[od["ref"]][2]
            if z < bz:
                bz, best = z, od
        order = best["polys"] if best else range(len(mesh["polys"]))

        for pi in order:
            poly = mesh["polys"][pi]
            flags = (0xf001 | 0x0F00) & (poly["flags"] << 8)
            nx, ny, nz = ns[poly["normal"]]
            v0 = vs[poly["verts"][0]]
            if not (flags & F_2SIDE):
                if nx * v0[0] + ny * v0[1] + nz * v0[2] >= 0:
                    continue            # backface
            shade = shade_of(flags, nx, ny, nz)
            ci = (poly["color"] + shade) & 0xff
            pts = [pv[v] for v in poly["verts"]]
            fill_poly(img, None, pts, ci)

    pal = scene["pal"]
    px = bytearray()
    for i in img:
        r, g, b = pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]
        px += bytes(((r * 255) // 63, (g * 255) // 63, (b * 255) // 63))
    return px


def write_png(path, px, w, h):
    import binascii
    import zlib
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3])
                   for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c +
                struct.pack(">I", binascii.crc32(c) & 0xffffffff))
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


def main():
    scene = load_srv(sys.argv[1])
    if sys.argv[2] == "--montage":
        # 4x4 grid, matching the capture montage (frame 0 = 93.965s, 70.086fps,
        # sampled every 0.5s from 93.7 -> the capture's own grid)
        cols, rows = 4, 4
        out = bytearray(320 * cols * 200 * rows * 3)
        for i in range(cols * rows):
            t = 93.7 + i * 0.5 + 0.2         # capture -> soundtrack time
            fi = int(round((t - 93.965) * 70.086))
            fi = max(0, min(len(scene["frames"]) - 1, fi))
            px = render(scene, fi)
            cx, cy = (i % cols) * 320, (i // cols) * 200
            for y in range(200):
                so = y * 320 * 3
                do = ((cy + y) * 320 * cols + cx) * 3
                out[do:do + 320 * 3] = px[so:so + 320 * 3]
        write_png(sys.argv[3], out, 320 * cols, 200 * rows)
    else:
        px = render(scene, int(sys.argv[2]))
        write_png(sys.argv[3], px, 320, 200)
    print("wrote", sys.argv[3])


if __name__ == "__main__":
    main()
