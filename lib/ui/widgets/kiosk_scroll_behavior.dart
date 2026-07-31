import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Lets a scroll view be dragged with a mouse or a finger, not just the wheel —
/// a wall display is driven by a USB mouse or a finger, neither of which gets
/// drag-to-scroll from the desktop default (which only scrolls on the wheel).
class KioskScrollBehavior extends MaterialScrollBehavior {
  const KioskScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };

  /// Callers paint their own always-visible thumb, so suppress the one the
  /// Material behaviour adds on desktop hosts — otherwise the Pi (Linux) shows
  /// two stacked scrollbars.
  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  /// No glow or stretch at the ends: on an always-on board an overscroll
  /// animation reads as a rendering fault rather than feedback.
  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}
