// Video type grid layout — chen 2026-11-17: 影视分类页显示不全.
// Screenshot (iPhone Air, 420pt logical): the 3rd column posters looked
// cut at the right edge and row 3 showed only 2 posters. This test
// renders the real VideoPosterGrid in the type page's exact sliver
// structure (SliverPadding 14 + SliverToBoxAdapter inside a
// CustomScrollView) and asserts every card sits fully inside the
// viewport, with equal columns and 12pt gaps.
//
// Root cause (proven by this test failing before the fix): the grid's
// fixed childAspectRatio 0.58 gave cells 12pt too short for the card
// content (poster 2:3 + 39.25pt of title/meta), so every card
// overflowed its cell and the meta line painted into the row gap.
// Horizontal fit was fine all along (3rd column complete).
// The fix derives the ratio from the measured width, so it is exact
// at any width — locked here at 420pt and 390pt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/video_poster_card.dart';

List<VideoItem> _items(int n) => List.generate(
      n,
      (i) => VideoItem(
        source: 's',
        sourceName: 's',
        vodId: 'v$i',
        name: '剧名$i',
        year: '2026',
        type: '国产剧',
      ),
    );

Widget _page(List<VideoItem> items) => MaterialApp(
      theme: HaoThemes.of(HaoThemeId.appleGlass).light,
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                    sliver: SliverToBoxAdapter(
                      child: VideoPosterGrid(
                        items: items,
                        onTapItem: (_) {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

/// Expected cell height for a grid of width [logicalWidth]:
/// SliverPadding takes 14pt on each side, 2 x 12pt column gaps.
/// Poster is 2:3, text block is [kVideoPosterCardTextHeight].
double _cellHeight(double logicalWidth) {
  final colW = (logicalWidth - 28 - 2 * 12) / 3;
  return colW * 3 / 2 + kVideoPosterCardTextHeight;
}

Future<void> _pumpGrid(
  WidgetTester tester,
  double logicalWidth,
  List<VideoItem> items,
) async {
  tester.view.physicalSize = Size(logicalWidth * 3, 2736);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_page(items));
  await tester.pump();
}

/// All cards fully inside the viewport, exact cell height, no overflow.
/// (Any RenderFlex overflow throws during pump and fails the test.)
void _assertGridFits(WidgetTester tester, double logicalWidth, int count) {
  final cards = find.byType(VideoPosterCard);
  expect(cards, findsNWidgets(count));
  final cellH = _cellHeight(logicalWidth);
  for (var i = 0; i < count; i++) {
    final r = tester.getRect(cards.at(i));
    // ignore: avoid_print
    print('card $i: left=${r.left.toStringAsFixed(1)} '
        'right=${r.right.toStringAsFixed(1)} '
        'top=${r.top.toStringAsFixed(1)} '
        'h=${r.height.toStringAsFixed(1)}');
    expect(r.left, greaterThanOrEqualTo(14.0 - 0.01),
        reason: 'card $i left');
    expect(r.right, lessThanOrEqualTo(logicalWidth - 14.0 + 0.01),
        reason: 'card $i right');
    // Card content fills its cell exactly — no overflow, no slack.
    expect(r.height, closeTo(cellH, 0.5), reason: 'card $i height');
  }
  // Columns equal width with 12pt gaps.
  final c0 = tester.getRect(cards.at(0));
  final c1 = tester.getRect(cards.at(1));
  final c2 = tester.getRect(cards.at(2));
  expect(c1.left - c0.right, closeTo(12.0, 0.5));
  expect(c2.left - c1.right, closeTo(12.0, 0.5));
  expect(c0.width, closeTo(c1.width, 0.5));
  expect(c1.width, closeTo(c2.width, 0.5));
  // Row pitch = cell height + 16pt row gap.
  final r3 = tester.getRect(cards.at(3));
  expect(r3.top - c0.top, closeTo(cellH + 16, 0.5), reason: 'row pitch');
  // Meta line stays inside its card (not painted into the row gap).
  final meta = tester.getRect(find.text('2026 · 国产剧').first);
  expect(meta.bottom, lessThanOrEqualTo(c0.bottom + 0.5),
      reason: 'meta inside card');
  // Row 3 is a full row of 3 when 9 items are present.
  if (count >= 9) {
    final r6 = tester.getRect(cards.at(6));
    final r8 = tester.getRect(cards.at(8));
    expect(r6.top, closeTo(r8.top, 0.5));
  }
}

void main() {
  testWidgets('9 items at 420pt: all 3 columns fully inside viewport',
      (tester) async {
    await _pumpGrid(tester, 420, _items(9));
    _assertGridFits(tester, 420, 9);
  });

  testWidgets('9 items at 390pt: ratio is exact at narrower widths too',
      (tester) async {
    await _pumpGrid(tester, 390, _items(9));
    _assertGridFits(tester, 390, 9);
  });

  testWidgets('8 items: last row has 2 cards, third cell empty',
      (tester) async {
    await _pumpGrid(tester, 420, _items(8));
    final cards = find.byType(VideoPosterCard);
    expect(cards, findsNWidgets(8));
    for (var i = 0; i < 8; i++) {
      final r = tester.getRect(cards.at(i));
      expect(r.right, lessThanOrEqualTo(420.0 - 14.0 + 0.01),
          reason: 'card $i right');
    }
  });
}
