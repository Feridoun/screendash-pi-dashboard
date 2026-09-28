import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../controllers/dim_controller.dart';
import 'admin_panel.dart';
import 'theme.dart';
import 'widgets/calendar_column.dart';
import 'widgets/celebration_overlay.dart';
import 'widgets/directory_column.dart';
import 'widgets/motd_banner.dart';
import 'widgets/photo_stage.dart';
import 'widgets/status_overlay.dart';

/// The single, pixel-stable kiosk layout.
///
///  ┌──────────────┬──────────────┬──────────────┐
///  │              │ CLOCK │ SKY  │ DIRECTORY    │
///  │  PHOTO       ├──────────────┤  grouped     │
///  │  STAGE       │ CALENDAR     │  contacts    │
///  │              │  14-day grid ├──────────────┤
///  │              │ MESSAGES     │ DOCTORS ROTA │
///  │              │  latest      │  who's in    │
///  ├──────────────┴──────────────┴──────────────┤
///  │                 MOTD banner                 │
///  └─────────────────────────────────────────────┘
///
/// The three columns are equal thirds of the width.
///
/// A status overlay floats bottom-right of the column area — confined above
/// the banner so its config/refresh icons never sit over the notice
/// controls, which float in that same corner of the banner — and the whole
/// thing sits under an animated dim scrim.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashTheme.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // --- Main content: three columns over a full-width banner ---
          Column(
            children: [
              Expanded(
                // Nested so the floating status icons stay confined to the
                // column area and can never sit over the banner below — its
                // own controls float in the same bottom-right corner.
                child: Stack(
                  fit: StackFit.expand,
                  children: const [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Three equal thirds: photo, calendar, directory.
                        Expanded(child: PhotoStage()),
                        _ColumnDivider(),
                        Expanded(child: CalendarColumn()),
                        _ColumnDivider(),
                        Expanded(child: DirectoryColumn()),
                      ],
                    ),

                    // --- Floating status (config gear + refresh dot) ---
                    StatusOverlay(),
                  ],
                ),
              ),
              const MotdBanner(),
            ],
          ),

          // --- Brief burst when a new notice or photo lands ---
          const CelebrationOverlay(),

          // --- Dim scrim: smooth software dimming on top of everything ---
          // Deliberately last: a 3am arrival celebrates behind the night scrim
          // rather than lighting the room.
          const _DimScrim(),

          // --- Hidden admin trigger ---
          // A long-press in the very top-left corner opens the recovery console
          // (network diagnostics, Wi-Fi, Tailscale). Invisible and cornered on
          // purpose: it's for whoever is setting the board up, not passers-by.
          // Sits above the scrim so it still works on a dimmed panel.
          const _AdminHotCorner(),
        ],
      ),
    );
  }
}

/// An invisible long-press target in the top-left corner. Opens [AdminPanel].
class _AdminHotCorner extends StatelessWidget {
  const _AdminHotCorner();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Deliberately long, so it can't be triggered by an ordinary tap and
        // never fires while someone is using the board normally.
        onLongPress: () => AdminPanel.open(context),
        child: const SizedBox(width: 96, height: 96),
      ),
    );
  }
}

/// A hairline rule between columns.
class _ColumnDivider extends StatelessWidget {
  const _ColumnDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, color: DashTheme.line);
  }
}

/// A black overlay whose opacity is driven by the DimController. Animates
/// smoothly so the day→evening transition fades rather than snaps.
///
/// Waking it is primarily a matter of moving the mouse: any pointer movement
/// over the board relights the panel, and keeps the wake window rolling while
/// someone is still there, without them having to press anything.
///
/// Touch has no hover, so while the scrim is up it also swallows taps and turns
/// them into a wake: on a dimmed or blanked screen the first touch relights the
/// panel rather than hitting whatever button happens to sit underneath. Fully
/// bright, it is pointer-transparent and the dashboard behaves normally.
class _DimScrim extends StatelessWidget {
  const _DimScrim();

  @override
  Widget build(BuildContext context) {
    final dim = context.watch<DimController>();
    final scrim = AnimatedContainer(
      duration: AppConfig.photoFade,
      curve: Curves.easeInOut,
      color: Colors.black.withValues(alpha: dim.scrimOpacity),
    );

    // `opaque: false` keeps this a passive observer: it reports hovers without
    // claiming them, so cursors and hover effects underneath still work, and it
    // stays mounted even while bright so a moving mouse can extend the window.
    return MouseRegion(
      opaque: false,
      onHover: (_) {
        if (dim.isDark || dim.isAwake) dim.wake();
      },
      child: dim.isDark
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dim.wake,
              child: scrim,
            )
          : IgnorePointer(child: scrim),
    );
  }
}
