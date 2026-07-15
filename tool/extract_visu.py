#!/usr/bin/env python3
"""Extract a VISU scene (the original Second Reality 3D engine's RUNTIME data)
into one `.srv` asset for the Flutter port.

The demo does NOT evaluate 3D Studio keyframes at runtime. Sami Tammilehto's
VISU engine ships a *compiled* scene:

  <SCENE>.00M   16-byte header, 256*3 VGA palette, then the object table
                (word conum, then conum-1 words: which .0NN object each co[]
                slot uses).  co[0] is always the camera.
  <SCENE>.0NN   one object: chunked "VERS/NAME/VERT/NORM/POLY/ORD0/ORDE../END "
                blocks (8-byte header: 4-char tag + int32 length).
  <SCENE>.0AA   list of animation streams to play (words, terminated by -1).
  <SCENE>.0AB   the animation stream itself: a delta-compressed, per-frame
                record of every object's 3x3 matrix + position, its on/off
                state, and the camera FOV.  Decoded exactly as U2A.C does.

Everything is fixed point with UNIT = 16384 (see VISU/C.H).  The 3x3 matrix
already contains rotation AND scale, and the vertices are in object space, so
a frame is simply  world = M * v + t  — there is no pivot, no keyframe
interpolation and no separate scale track to apply.  (Applying the .PRJ SCL
track on top of the mesh is a classic double-scale bug; the runtime data has
none of that ambiguity.)

.srv format (little-endian):
  "SRV1"
  u8  objCount                 -- co[] slots, including co[0] = camera
  u8  meshCount
  u8  objMesh[objCount]        -- mesh index per co[] slot; 255 for the camera
  768 bytes                    -- 6-bit VGA palette from the .00M
  per mesh:
    u8 nameLen, name
    u16 vertCount, i32 x,y,z per vertex, then u16 normalIndex per vertex
    u16 normCount, u16 basicNormCount, i16 x,y,z per normal
    u16 polyCount, per poly:
      u8 sides, u8 flags, u8 color, u16 normal, u16 vertexIndex[sides]
    u16 centerVertex, u8 orderCount, per order:
      u16 refVertex, u16 polyCount, u16 polyIndex[polyCount]
  u16 frameCount, per frame:
    u16 fov                                       -- 65536 == 360 degrees
    per co[] slot: u8 on, i32 m[9], i32 x, i32 y, i32 z

Usage:
  python3 tool/extract_visu.py original/VISU/C/SCENE U2A assets/meshes/u2a.srv
"""
import struct
import sys
from pathlib import Path

UNIT = 16384


# ---- object file ("VERS/NAME/VERT/NORM/POLY/ORD0/ORDE/END ") ---------------
def parse_object(data):
    """Parse one VISU .0NN object (VISU.C:vis_loadobject)."""
    o = {"name": "", "verts": [], "vertNormals": [], "norms": [], "nnum1": 0,
         "polys": [], "orders": [], "centerVertex": 0}
    offsets = {}   # polydata byte offset -> poly index (to resolve ORD lists)
    ord_raw = []   # (isOrd0, [words]) in file order
    i = 0
    while i + 8 <= len(data):
        tag = data[i:i + 4]
        length = struct.unpack_from("<i", data, i + 4)[0]
        body = i + 8
        if tag == b"END ":
            break
        elif tag == b"NAME":
            o["name"] = data[body:data.index(b"\0", body)].decode("latin1")
        elif tag == b"VERT":
            # word vnum, word (unused), then vlist[]: long x,y,z; int normal;
            # int RESERVED  (CD.H:s_vlist -> 16 bytes each)
            n = struct.unpack_from("<h", data, body)[0]
            off = body + 4
            o["verts"] = [struct.unpack_from("<iii", data, off + k * 16)
                          for k in range(n)]
            # vlist.normal — each vertex names its OWN normal (the gouraud
            # normals, nnum1..nnum). ADRAW.ASM's gouraud path shades a vertex
            # from this, not from the face normal.
            o["vertNormals"] = [
                struct.unpack_from("<H", data, off + k * 16 + 12)[0]
                for k in range(n)]
        elif tag == b"NORM":
            # word nnum, word nnum1, then nlist[]: int x,y,z,RESERVED (8 bytes)
            n, n1 = struct.unpack_from("<hh", data, body)
            o["nnum1"] = n1
            off = body + 4
            o["norms"] = [struct.unpack_from("<hhh", data, off + k * 8)
                          for k in range(n)]
        elif tag == b"POLY":
            # polydata: a leading zero word, then variable-length records
            # (CD.H): byte sides, byte flags, byte color, byte RESERVED,
            # word normal, word vertex[sides].  Records run to the end of the
            # block; a record with sides==0 terminates.
            p = body + 2
            end = body + length
            while p + 6 <= end:
                sides, flags, color = data[p], data[p + 1], data[p + 2]
                if sides == 0:
                    break
                normal = struct.unpack_from("<H", data, p + 4)[0]
                vs = struct.unpack_from("<" + "H" * sides, data, p + 6)
                # ORD lists reference polygons by their byte offset within the
                # polydata block (ADRAW.ASM indexes straight into it).
                offsets[p - body] = len(o["polys"])
                o["polys"].append({"sides": sides, "flags": flags,
                                   "color": color, "normal": normal,
                                   "verts": list(vs)})
                p += 6 + 2 * sides
        elif tag[:3] == b"ORD":
            # word count (in words), word closest/center vertex, then polygon
            # offsets, terminated by 0.  ORD0 = unsorted (its [1] is the object's
            # CENTER vertex, used for the object z-sort); ORDE = one
            # back-to-front list per view octant (VISU.C:vis_drawobject picks the
            # list whose reference vertex is nearest the camera).
            words = struct.unpack_from("<%dh" % (length // 2), data, body)
            ord_raw.append((tag == b"ORD0", list(words)))
        i = body + length

    for is_ord0, words in ord_raw:
        ref = words[1] & 0xffff
        polys = []
        for w in words[2:]:
            if w == 0:
                break
            polys.append(offsets[w & 0xffff])
        if is_ord0:
            o["centerVertex"] = ref
        else:
            o["orders"].append({"ref": ref, "polys": polys})
    return o


# ---- animation stream (U2A.C: the inner `while(!xit)` parser) --------------
class Stream:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def lsget(self, f):
        """U2A.C:lsget — 0/1/2/4-byte little-endian signed value."""
        f &= 3
        if f == 0:
            return 0
        if f == 1:
            return s8(self.u8())
        if f == 2:
            lo = self.u8()
            return lo | (s8(self.u8()) << 8)
        lo = self.u8() | (self.u8() << 8) | (self.u8() << 16)
        return lo | (s8(self.u8()) << 24)


def s8(v):
    return v - 256 if v > 127 else v


def parse_anim(data, conum):
    """Decode the delta stream into absolute per-frame transforms.

    Mirrors U2A.C exactly: object state persists across frames, each token
    ADDS to the object's matrix/position, and a frame ends at the 0xff <fov>
    token.  0xff 0xff ends the stream.
    """
    sp = Stream(data)
    r = [{"m": [0] * 9, "x": 0, "y": 0, "z": 0} for _ in range(conum)]
    on = [0] * conum
    frames = []
    fov = 0
    done = False
    while not done and sp.p < len(data):
        # `onum = 0` ONCE PER FRAME, exactly as U2A.C/U2E.C do it. The object
        # number is STICKY: a token only ever carries the low nibble, and the
        # high bits stay whatever the last 0xc0-prefixed token set them to. U2A
        # has 4 co[] slots, so its high bits are always 0 and resetting per token
        # looks identical — U2E has 58, and resetting per token addresses the
        # wrong object for every token in the frame after the first.
        onum = 0
        while True:
            if sp.p >= len(data):
                done = True
                break
            a = sp.u8()
            if a == 0xff:
                a = sp.u8()
                if a <= 0x7f:
                    fov = a << 8          # end of frame
                    break
                if a == 0xff:
                    done = True           # end of stream
                    break
            if (a & 0xc0) == 0xc0:
                onum = (a & 0x3f) << 4
                a = sp.u8()
            onum = (onum & 0xff0) | (a & 0xf)
            if (a & 0xc0) == 0x80:
                on[onum] = 1
            elif (a & 0xc0) == 0x40:
                on[onum] = 0
            pflag = 0
            sel = a & 0x30
            if sel == 0x10:
                pflag = sp.u8()
            elif sel == 0x20:
                pflag = sp.u8() | (sp.u8() << 8)
            elif sel == 0x30:
                pflag = sp.u8() | (sp.u8() << 8) | (sp.u8() << 16)
            ro = r[onum]
            ro["x"] += sp.lsget(pflag)
            ro["y"] += sp.lsget(pflag >> 2)
            ro["z"] += sp.lsget(pflag >> 4)
            width = 2 if (pflag & 0x40) else 1   # word vs byte matrix deltas
            for b in range(9):
                if pflag & (0x80 << b):
                    ro["m"][b] += sp.lsget(width)
        if done:
            break
        frames.append((fov,
                       [{"m": list(o["m"]), "x": o["x"], "y": o["y"],
                         "z": o["z"]} for o in r],
                       list(on)))
    return frames


def encode(pal, obj_mesh, meshes, frames):
    out = bytearray(b"SRV1")
    out += struct.pack("<BB", len(obj_mesh), len(meshes))
    out += bytes(obj_mesh)
    out += pal
    for m in meshes:
        nb = m["name"].encode("latin1")[:255]
        out += struct.pack("<B", len(nb)) + nb
        out += struct.pack("<H", len(m["verts"]))
        for v in m["verts"]:
            out += struct.pack("<iii", *v)
        for vn in m["vertNormals"]:
            out += struct.pack("<H", vn)
        out += struct.pack("<HH", len(m["norms"]), m["nnum1"])
        for n in m["norms"]:
            out += struct.pack("<hhh", *n)
        out += struct.pack("<H", len(m["polys"]))
        for p in m["polys"]:
            out += struct.pack("<BBBH", p["sides"], p["flags"], p["color"],
                               p["normal"])
            out += struct.pack("<" + "H" * p["sides"], *p["verts"])
        # center vertex (object z-sort key) + the 8 direction-sorted draw orders
        out += struct.pack("<HB", m["centerVertex"], len(m["orders"]))
        for od in m["orders"]:
            out += struct.pack("<HH", od["ref"], len(od["polys"]))
            out += struct.pack("<" + "H" * len(od["polys"]), *od["polys"])
    out += struct.pack("<H", len(frames))
    for fov, rs, on in frames:
        out += struct.pack("<H", fov)
        for i, ro in enumerate(rs):
            out += struct.pack("<B", on[i])
            out += struct.pack("<9i", *ro["m"])
            out += struct.pack("<iii", ro["x"], ro["y"], ro["z"])
    return bytes(out)


def main():
    scene_dir, scene, dst = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])

    m00 = (scene_dir / f"{scene}.00M").read_bytes()
    table_off = struct.unpack_from("<i", m00, 4)[0]
    pal = m00[16:16 + 768]
    n = (len(m00) - table_off) // 2
    words = struct.unpack_from("<%dh" % n, m00, table_off)
    conum = words[0]
    # co[0] is the camera; co[1..conum-1] each name a .0NN object file.
    indices = list(words[1:conum])

    # Load each distinct object file once; co[] slots may share a mesh.
    uniq = []
    for e in indices:
        if e not in uniq:
            uniq.append(e)
    meshes = [parse_object((scene_dir / f"{scene}.{e:03d}").read_bytes())
              for e in uniq]
    obj_mesh = [255] + [uniq.index(e) for e in indices]  # 255 = camera

    # .0AA lists the animation streams; the demo's scenes have exactly one.
    aa = (scene_dir / f"{scene}.0AA").read_bytes()
    a = struct.unpack_from("<h", aa, 0)[0]
    anim_name = f"{scene}.0{chr(a // 10 + ord('A'))}{chr(a % 10 + ord('A'))}"
    frames = parse_anim((scene_dir / anim_name).read_bytes(), conum)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(encode(pal, obj_mesh, meshes, frames))

    print(f"{dst}: {len(frames)} frames, {conum} co[] slots "
          f"({len(meshes)} meshes), anim={anim_name}")
    for i, e in enumerate(indices):
        mi = uniq.index(e)
        print(f"  co[{i + 1}] -> {scene}.{e:03d} '{meshes[mi]['name']}'")
    for m in meshes:
        print(f"  '{m['name']}': {len(m['verts'])} v, {len(m['norms'])} n "
              f"({m['nnum1']} basic), {len(m['polys'])} polys")


if __name__ == "__main__":
    main()
