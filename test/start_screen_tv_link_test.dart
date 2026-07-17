// The landing screen's primio.dev link must NOT be a link on an Android TV:
// Play's TV bar (TV-WB) says a TV app must not attempt to launch a browser, and
// most TVs have none to launch.
//
// This is derivation logic, not a demo effect (CLAUDE.md: unit-test the second,
// never the first). The discriminator is structural rather than cosmetic: the
// link path builds a Text('primio.dev') inside a Listener (see
// engine/external_link_stub.dart), while the TV path is a plain TextSpan in the
// surrounding paragraph, which is neither.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/tv.dart';
import 'package:second_reality/start_screen.dart';

Future<void> _pumpLanding(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: StartScreen(onStart: () {}),
  ));
  // The backdrop animates forever, so pumpAndSettle would time out.
  await tester.pump(const Duration(milliseconds: 16));
}

bool _hasLinkWidget(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => t.data == 'primio.dev');

void main() {
  final previous = isAndroidTv;
  tearDown(() => isAndroidTv = previous);

  testWidgets('on a TV, primio.dev is plain text and not a link', (t) async {
    isAndroidTv = true;
    await _pumpLanding(t);

    expect(_hasLinkWidget(t), isFalse,
        reason: 'the TV build must not build the tappable link widget');
    // The words are still in the sentence, just not linked.
    expect(find.textContaining('primio.dev', findRichText: true), findsWidgets);
  });

  testWidgets('off a TV, primio.dev is still a real link', (t) async {
    isAndroidTv = false;
    await _pumpLanding(t);

    expect(_hasLinkWidget(t), isTrue,
        reason: 'every non-TV build keeps the outbound link');
  });
}
