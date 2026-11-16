// App shell — 4 bottom tabs: 影视 / 直播 / 音乐 / 设置. No home page.
//
// Swipe guard (fix 7): on every live page a horizontal swipe must never
// change the bottom tab. Implemented by disabling PageView swipe while the
// current tab IS live; the tab bar itself stays visible and tappable.
// Swiping INTO live from another tab still works, because the guard reads
// the CURRENT page. The live room is a pushed route (no tab bar at all
// while open — fix 17.3), separate from this guard.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../domains/live/presentation/live_tab_page.dart';
import '../features/music/music_tab_page.dart';
import '../features/settings/settings_tab_page.dart';
import '../features/video/video_tab_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const int liveTabIndex = 1;

  final _pageController = PageController();
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    VideoTabPage(),
    LiveTabPage(),
    MusicTabPage(),
    SettingsTabPage(),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    _dismissOverlays();
    setState(() => _currentIndex = index);
    _pageController.jumpToPage(index);
  }

  /// Audit P1-6: an open sheet/dialog/snackbar must never float over the
  /// new tab after a tab switch. Dismiss all overlays before changing
  /// pages (both tap and swipe paths go through here — onPageChanged
  /// also calls it, because a swipe can land while a sheet is open).
  void _dismissOverlays() {
    if (Get.isDialogOpen == true) Get.back();
    if (Get.isBottomSheetOpen == true) Get.back();
    Get.closeAllSnackbars();
  }

  @override
  Widget build(BuildContext context) {
    final isLiveTab = _currentIndex == liveTabIndex;
    return Scaffold(
      body: PageView(
        controller: _pageController,
        // Swipe guard (fix 7): no swipe navigation while on the live tab.
        physics: isLiveTab
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: (index) {
          _dismissOverlays();
          setState(() => _currentIndex = index);
        },
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.movie), label: '影视'),
          BottomNavigationBarItem(icon: Icon(Icons.live_tv), label: '直播'),
          BottomNavigationBarItem(icon: Icon(Icons.music_note), label: '音乐'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
