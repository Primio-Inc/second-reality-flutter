// Glenz object vector data, transcribed VERBATIM from GLENZ/MAIN.C.
//
// Inner object `points[]` (ZZZ=50): cube corners at ±100*ZZZ = ±5000 with an
// apex pushed out of each face at ±170*ZZZ = ±8500. Original units — the
// renderer must NOT normalise; the scene scales by (scale*64)>>15 and places
// the object at (oxp, ypos+1500+oyp, 7500+ozp), projected with
// sx=256*x/z+160, sy=213*y/z+130 onto the 320x200 screen (VID.ASM).
//
// Outer object `pointsb[]` (QQQ=99): cube ±60*QQQ = ±5940, apexes ±105*QQQ =
// ±10395, scaled by (bscale*64)>>15.

/// Inner glenz: 14 vertices, xyz interleaved (original units).
const List<double> glenzVerts = [
  -5000, -5000, -5000, // 0
  5000, -5000, -5000, // 1
  5000, 5000, -5000, // 2
  -5000, 5000, -5000, // 3
  -5000, -5000, 5000, // 4
  5000, -5000, 5000, // 5
  5000, 5000, 5000, // 6
  -5000, 5000, 5000, // 7
  0, 0, -8500, // 8  -Z apex
  0, 0, 8500, // 9  +Z apex
  8500, 0, 0, // 10 +X apex
  -8500, 0, 0, // 11 -X apex
  0, 8500, 0, // 12 +Y apex
  0, -8500, 0, // 13 -Y apex
];

/// Outer glenz: 14 vertices, xyz interleaved (original units).
const List<double> glenzOuterVerts = [
  -5940, -5940, -5940, // 0
  5940, -5940, -5940, // 1
  5940, 5940, -5940, // 2
  -5940, 5940, -5940, // 3
  -5940, -5940, 5940, // 4
  5940, -5940, 5940, // 5
  5940, 5940, 5940, // 6
  -5940, 5940, 5940, // 7
  0, 0, -10395, // 8
  0, 0, 10395, // 9
  10395, 0, 0, // 10
  -10395, 0, 0, // 11
  0, 10395, 0, // 12
  0, -10395, 0, // 13
];

/// Inner triangles as [v0, v1, v2, code] where `code` is the original
/// epolys[] palette-add value (0x4002..0x4030 low byte: 2,4,6..0x30).
const List<List<int>> glenzTris = [
  [0, 1, 8, 0x02], [1, 2, 8, 0x04], [2, 3, 8, 0x06], [3, 0, 8, 0x08],
  [2, 1, 10, 0x0a], [1, 5, 10, 0x0c], [5, 6, 10, 0x0e], [6, 2, 10, 0x10],
  [2, 6, 12, 0x12], [6, 7, 12, 0x14], [7, 3, 12, 0x16], [3, 2, 12, 0x18],
  [0, 3, 11, 0x1a], [3, 7, 11, 0x1c], [7, 4, 11, 0x1e], [4, 0, 11, 0x20],
  [5, 1, 13, 0x22], [1, 0, 13, 0x24], [0, 4, 13, 0x26], [4, 5, 13, 0x28],
  [5, 4, 9, 0x2a], [4, 7, 9, 0x2c], [7, 6, 9, 0x2e], [6, 5, 9, 0x30],
];

/// Outer triangles (epolysb[]): same topology, codes alternate 4,2.
/// Palette: add 2 -> red 30/63, add 4 -> red 20/63, both (overlap) -> 50/63 —
/// i.e. ADDITIVE red: code 2 = RGB(120,0,0), code 4 = RGB(80,0,0) in 8-bit.
const List<List<int>> glenzOuterTris = [
  [0, 1, 8, 4], [1, 2, 8, 2], [2, 3, 8, 4], [3, 0, 8, 2],
  [2, 1, 10, 4], [1, 5, 10, 2], [5, 6, 10, 4], [6, 2, 10, 2],
  [2, 6, 12, 4], [6, 7, 12, 2], [7, 3, 12, 4], [3, 2, 12, 2],
  [0, 3, 11, 4], [3, 7, 11, 2], [7, 4, 11, 4], [4, 0, 11, 2],
  [5, 1, 13, 4], [1, 0, 13, 2], [0, 4, 13, 4], [4, 5, 13, 2],
  [5, 4, 9, 4], [4, 7, 9, 2], [7, 6, 9, 4], [6, 5, 9, 2],
];
