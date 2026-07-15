#!/usr/bin/env python3
"""Extract 3D vector meshes from the original Second Reality asset files into
the .svm format used by the Flutter port. Supports Autodesk 3D Studio binary
(.3DS) and ASCII (.ASC) exports — the demo's 3D objects (intro ship
PXLSHIP.3DS, city CITY.ASC, etc.).

.svm format (little-endian), one or more meshes concatenated after a header:
  "SVM1" | u16 meshCount
  per mesh: u8 nameLen | name | u32 vertexCount | u32 faceCount
            | vertices: vertexCount * 3 float32 (x,y,z)
            | faces:    faceCount * 3 u32 (indices)

Usage:
  python3 tool/extract_mesh.py <in.3DS|in.ASC> <out.svm> [--preview out.png]
"""
import re
import struct
import subprocess
import sys
from pathlib import Path

# ---- Autodesk 3DS binary --------------------------------------------------
CHUNK_MAIN = 0x4D4D
CHUNK_PRJ = 0xC23D  # 3D Studio .PRJ project files wrap the edit data here
CHUNK_EDIT = 0x3D3D
CHUNK_OBJECT = 0x4000
CHUNK_TRIMESH = 0x4100
CHUNK_VERTS = 0x4110
CHUNK_FACES = 0x4120


def parse_3ds(data):
    meshes = []  # (name, verts[(x,y,z)], faces[(a,b,c)])

    def walk(start, end, ctx):
        i = start
        while i + 6 <= end:
            cid, clen = struct.unpack_from("<HI", data, i)
            body, nxt = i + 6, i + clen
            if clen < 6 or nxt > end:
                break
            if cid == CHUNK_MAIN or cid == CHUNK_EDIT or cid == CHUNK_PRJ:
                walk(body, nxt, ctx)
            elif cid == CHUNK_OBJECT:
                j = body
                while data[j] != 0:
                    j += 1
                name = data[body:j].decode("latin1")
                mesh = {"name": name, "verts": [], "faces": []}
                meshes.append(mesh)
                walk(j + 1, nxt, mesh)
            elif cid == CHUNK_TRIMESH:
                walk(body, nxt, ctx)
            elif cid == CHUNK_VERTS:
                (n,) = struct.unpack_from("<H", data, body)
                off = body + 2
                ctx["verts"] = [
                    struct.unpack_from("<fff", data, off + k * 12)
                    for k in range(n)
                ]
            elif cid == CHUNK_FACES:
                (n,) = struct.unpack_from("<H", data, body)
                off = body + 2
                ctx["faces"] = [
                    struct.unpack_from("<HHH", data, off + k * 8)  # 4th=flags
                    for k in range(n)
                ]
            i = nxt

    walk(0, len(data), None)
    return [(m["name"], m["verts"], m["faces"])
            for m in meshes if m["verts"] and m["faces"]]


# ---- 3DS ASCII (.ASC) -----------------------------------------------------
def parse_asc(text):
    meshes = []
    blocks = re.split(r'Named object:\s*"([^"]*)"', text)
    # blocks[0] preamble, then name, body, name, body, ...
    for k in range(1, len(blocks), 2):
        name, body = blocks[k], blocks[k + 1]
        verts = [(float(x), float(y), float(z)) for x, y, z in re.findall(
            r"Vertex\s+\d+:\s*X:\s*([-\d.eE]+)\s+Y:\s*([-\d.eE]+)\s+Z:\s*"
            r"([-\d.eE]+)", body)]
        faces = [(int(a), int(b), int(c)) for a, b, c in re.findall(
            r"Face\s+\d+:\s*A:\s*(\d+)\s+B:\s*(\d+)\s+C:\s*(\d+)", body)]
        if verts and faces:
            meshes.append((name, verts, faces))
    return meshes


def encode_svm(meshes):
    out = bytearray(b"SVM1")
    out += struct.pack("<H", len(meshes))
    for name, verts, faces in meshes:
        nb = name.encode("latin1")[:255]
        out += struct.pack("<B", len(nb)) + nb
        out += struct.pack("<II", len(verts), len(faces))
        for v in verts:
            out += struct.pack("<fff", *v)
        for f in faces:
            out += struct.pack("<III", f[0], f[1], f[2])
    return bytes(out)


def preview(meshes, path):
    # Orthographic wireframe from the +Z direction, auto-fit, for a sanity look.
    W = H = 400
    allv = [v for _, vs, _ in meshes for v in vs]
    xs = [v[0] for v in allv]
    ys = [v[1] for v in allv]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    sc = 0.9 * min(W / (maxx - minx + 1e-6), H / (maxy - miny + 1e-6))
    cxw = (minx + maxx) / 2
    cyw = (miny + maxy) / 2
    img = [[0] * W for _ in range(H)]

    def put(x, y):
        if 0 <= x < W and 0 <= y < H:
            img[y][x] = 255

    def line(x0, y0, x1, y1):
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        while True:
            put(x0, y0)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x0 += sx
            if e2 < dx:
                err += dx
                y0 += sy

    def proj(v):
        return (int(W / 2 + (v[0] - cxw) * sc), int(H / 2 - (v[1] - cyw) * sc))

    for _, verts, faces in meshes:
        for a, b, c in faces:
            pa, pb, pc = proj(verts[a]), proj(verts[b]), proj(verts[c])
            line(*pa, *pb)
            line(*pb, *pc)
            line(*pc, *pa)
    ppm = bytearray(f"P6\n{W} {H}\n255\n".encode())
    for row in img:
        for v in row:
            ppm += bytes((v, v, v))
    Path("/tmp/_mesh.ppm").write_bytes(ppm)
    subprocess.run(["sips", "-s", "format", "png", "/tmp/_mesh.ppm",
                    "--out", path], capture_output=True)
    print(f"preview -> {path}")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    raw = Path(src).read_bytes()
    if src.upper().endswith(".ASC"):
        meshes = parse_asc(raw.decode("latin1"))
    else:
        meshes = parse_3ds(raw)
    # Optional: keep only the named sub-mesh(es) (comma-separated).
    if "--only" in sys.argv:
        want = set(sys.argv[sys.argv.index("--only") + 1].split(","))
        meshes = [m for m in meshes if m[0] in want]
    Path(dst).write_bytes(encode_svm(meshes))
    total_v = sum(len(v) for _, v, _ in meshes)
    total_f = sum(len(f) for _, _, f in meshes)
    print(f"{dst}: {len(meshes)} mesh(es), {total_v} verts, {total_f} faces")
    for name, v, f in meshes:
        print(f"  '{name}': {len(v)} v, {len(f)} f")
    if "--preview" in sys.argv:
        preview(meshes, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
