import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Draws a programmatic tablet device frame (landscape, 4:3 screen — the
/// original VGA display ratio) around the demo. The demo always renders inside
/// the tablet's screen at exactly 4:3; the body, bezel, rounded corners and
/// front camera are painted in code (no assets). Global requirement — the whole
/// demo runs inside this frame at the original ratio (see the porting notes).
class TabletFrame extends StatelessWidget {
  /// The demo screen content; it is given a 4:3 box to fill.
  final Widget screen;
  const TabletFrame({super.key, required this.screen});

  static const double _screenAspect = 4 / 3;
  static const double _bezelFrac = 0.055; // bezel = 5.5% of screen height

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (outerCtx, outer) {
        // Cosmetic breathing room above and below the tablet.
        final vPad = outer.maxHeight * 0.06;
        return Padding(
          padding: EdgeInsets.symmetric(vertical: vPad),
          child: _body(),
        );
      },
    );
  }

  Widget _body() {
    return Center(
      child: LayoutBuilder(
        builder: (ctx, c) {
          // Fit the tablet body (fixed aspect = 4:3 screen + uniform bezel)
          // inside the available space, constraining BOTH dimensions, then
          // derive the exact 4:3 screen from the body.
          final bodyAspect =
              (_screenAspect + 2 * _bezelFrac) / (1 + 2 * _bezelFrac);
          double bodyW, bodyH;
          if (c.maxWidth / c.maxHeight > bodyAspect) {
            bodyH = c.maxHeight;
            bodyW = bodyH * bodyAspect;
          } else {
            bodyW = c.maxWidth;
            bodyH = bodyW / bodyAspect;
          }
          final screenH = bodyH / (1 + 2 * _bezelFrac);
          final screenW = screenH * _screenAspect;
          final bezel = screenH * _bezelFrac;
          final bodyRadius = bezel * 1.9;
          final screenRadius = bezel * 0.85;

          return SizedBox(
            width: bodyW,
            height: bodyH,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Tablet body (brushed dark metal).
                Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3c3c42), Color(0xFF17171a)],
                    ),
                    borderRadius: BorderRadius.circular(bodyRadius),
                    border: Border.all(
                        color: const Color(0xFF505057),
                        width: math.max(1.0, bezel * 0.06)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xCC000000),
                        blurRadius: bezel * 1.8,
                        offset: Offset(0, bezel * 0.5),
                      ),
                    ],
                  ),
                ),
                // Screen (4:3), inset with rounded corners over black.
                SizedBox(
                  width: screenW,
                  height: screenH,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(screenRadius),
                    child: Container(color: Colors.black, child: screen),
                  ),
                ),
                // Front camera on the top bezel.
                Positioned(
                  top: bezel * 0.44,
                  child: Container(
                    width: bezel * 0.2,
                    height: bezel * 0.2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0b0b0d),
                      border: Border.all(
                          color: const Color(0xFF5a5a60),
                          width: math.max(0.5, bezel * 0.03)),
                    ),
                    child: Center(
                      child: Container(
                        width: bezel * 0.07,
                        height: bezel * 0.07,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF1c2b3a), // faint lens glint
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
