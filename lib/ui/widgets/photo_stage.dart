import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/photo_controller.dart';
import '../theme.dart';

/// The dominant region: the current team photo, cross-fading on each advance.
///
/// Decodes at [AppConfig.photoDecodeWidth] via [cacheWidth] so we never pin a
/// frame larger than the panel. [gaplessPlayback] avoids a white flash on swap.
///
/// Four ways to touch it, each with exactly one job:
///   * tapping the photo cycles how it's scaled into the panel (fill → fit →
///     zoom), because how a group shot is cropped is the thing people actually
///     want to change while standing in front of it;
///   * the arrows at the bottom step the rotation by hand;
///   * the pin button holds the current photo on screen;
///   * the trash button (tap twice to confirm) drops the current photo from
///     *this device's* rotation only — a local hide, not a backend delete.
///
/// The controls are deliberately quiet: they surface on hover or on any touch
/// and fade out again after [AppConfig.photoControlsLinger], so the wall stays
/// a photo and not a media player. The pin badge is the exception — while
/// pinned it stands, so nobody has to wonder why the wall stopped rotating.
class PhotoStage extends StatefulWidget {
  const PhotoStage({super.key});

  @override
  State<PhotoStage> createState() => _PhotoStageState();
}

/// How the photo is laid into the panel. Cycled by tapping the photo.
///
/// [zoom] is a plain scale on top of a cover fit rather than another [BoxFit]:
/// it's the "lean in on the faces" option, and there is no fit constant for
/// "cover, but more". It upscales past the decode width slightly, which is
/// fine at across-the-room viewing distance.
enum _PhotoScale {
  fill(BoxFit.cover, 1.0, Icons.crop_free, 'Fill'),
  fit(BoxFit.contain, 1.0, Icons.fit_screen_outlined, 'Fit'),
  zoom(BoxFit.cover, 1.5, Icons.zoom_in, 'Zoom');

  const _PhotoScale(this.boxFit, this.magnify, this.icon, this.label);

  final BoxFit boxFit;
  final double magnify;
  final IconData icon;
  final String label;

  _PhotoScale get next => values[(index + 1) % values.length];
}

class _PhotoStageState extends State<PhotoStage> {
  bool _hovering = false;

  /// Controls revealed by a touch (as opposed to a hovering cursor), which the
  /// panel mostly is — it's a touchscreen on a wall.
  bool _touched = false;
  Timer? _linger;

  _PhotoScale _scale = _PhotoScale.fill;

  /// First tap on the trash icon arms it; a second tap actually deletes. Reset
  /// whenever the controls bar itself hides, so an arm-then-walk-away can't
  /// leave a stray "confirm" waiting for the next visitor's first tap.
  bool _deleteArmed = false;

  bool get _controlsVisible => _hovering || _touched;

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  /// Show the controls and restart the countdown that hides them again.
  void _reveal() {
    _linger?.cancel();
    if (!_touched) setState(() => _touched = true);
    _linger = Timer(AppConfig.photoControlsLinger, () {
      if (mounted) {
        setState(() {
          _touched = false;
          _deleteArmed = false;
        });
      }
    });
  }

  void _cycleScale() {
    _reveal();
    setState(() => _scale = _scale.next);
  }

  /// First tap arms the delete button (and disarms on a second thought if the
  /// controls simply linger out); a second tap while armed actually removes
  /// the photo from this device's rotation.
  void _tapDelete(PhotoController photos) {
    _reveal();
    if (!_deleteArmed) {
      setState(() => _deleteArmed = true);
      return;
    }
    setState(() => _deleteArmed = false);
    photos.hideCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final photos = context.watch<PhotoController>();
    final file = photos.currentFile;

    return MouseRegion(
      cursor: photos.hasPhotos
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            // Opaque so the whole panel is a hit target, not just the pixels.
            behavior: HitTestBehavior.opaque,
            onTap: photos.hasPhotos ? _cycleScale : null,
            child: file == null
                ? const _PhotoPlaceholder()
                : ClipRect(
                    // Zoom paints outside the panel otherwise, over the calendar.
                    child: AnimatedSwitcher(
                      duration: AppConfig.photoFade,
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      // Keyed by path so this switcher cross-fades slowly on a
                      // photo change, and rebuilds fresh (no transition) when
                      // only the scale changed — that's the inner one's job.
                      child: KeyedSubtree(
                        key: ValueKey(file.path),
                        child: AnimatedSwitcher(
                          duration: AppConfig.photoScaleFade,
                          child: Transform.scale(
                            key: ValueKey(_scale),
                            scale: _scale.magnify,
                            child: Image.file(
                              file,
                              fit: _scale.boxFit,
                              width: double.infinity,
                              height: double.infinity,
                              cacheWidth: AppConfig.photoDecodeWidth,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => const _PhotoPlaceholder(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (photos.hasPhotos) ...[
            Positioned(
              top: 24,
              right: 24,
              child: _PinButton(
                pinned: photos.isPinned,
                // Pinned is a standing state; the hint only shows on approach.
                visible: photos.isPinned || _controlsVisible,
                onTap: () {
                  _reveal();
                  photos.togglePin();
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: _PhotoControls(
                  visible: _controlsVisible,
                  index: photos.index,
                  count: photos.count,
                  scale: _scale,
                  onPrevious: () {
                    _reveal();
                    photos.previous();
                  },
                  onNext: () {
                    _reveal();
                    photos.next();
                  },
                  onScale: _cycleScale,
                  deleteArmed: _deleteArmed,
                  onDelete: () => _tapDelete(photos),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The bottom bar: step back, position, step forward, and the current scale
/// mode — which is also a button, so the tap-the-photo gesture has a visible
/// counterpart for anyone who never discovers it.
class _PhotoControls extends StatelessWidget {
  const _PhotoControls({
    required this.visible,
    required this.index,
    required this.count,
    required this.scale,
    required this.onPrevious,
    required this.onNext,
    required this.onScale,
    required this.deleteArmed,
    required this.onDelete,
  });

  final bool visible;
  final int index;
  final int count;
  final _PhotoScale scale;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onScale;
  final bool deleteArmed;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // One photo can't be stepped through; leave the arrows visible but inert so
    // the bar doesn't change shape underneath a finger.
    final canStep = count > 1;

    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: DashTheme.ink.withValues(alpha: 0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ControlButton(
                icon: Icons.chevron_left,
                onTap: canStep ? onPrevious : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${index + 1} / $count',
                  style: TextStyle(
                    color: DashTheme.ink.withValues(alpha: 0.85),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    // Tabular so the bar doesn't jitter as the count ticks over.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              _ControlButton(
                icon: Icons.chevron_right,
                onTap: canStep ? onNext : null,
              ),
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: DashTheme.ink.withValues(alpha: 0.18),
              ),
              _ControlButton(
                icon: scale.icon,
                label: scale.label,
                onTap: onScale,
              ),
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: DashTheme.ink.withValues(alpha: 0.18),
              ),
              _ControlButton(
                icon: deleteArmed ? Icons.delete_forever : Icons.delete_outline,
                label: deleteArmed ? 'Confirm' : null,
                color: deleteArmed ? DashTheme.offline : null,
                onTap: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A roomy icon (optionally icon + label) tap target, sized for a finger at
/// arm's length rather than a mouse.
class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.onTap, this.label, this.color});

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;

  /// Override the default ink tone — used to pick out the armed delete button
  /// in [DashTheme.offline] rather than the usual neutral grey.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = this.color ?? DashTheme.ink.withValues(alpha: enabled ? 0.85 : 0.3);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(
                label!,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Top-right chip: solid while pinned, a faint outline as a hover hint. Tapping
/// it is now the only way to pin — the photo itself re-scales instead.
class _PinButton extends StatelessWidget {
  final bool pinned;
  final bool visible;
  final VoidCallback onTap;

  const _PinButton({
    required this.pinned,
    required this.visible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        // Faded out it is scenery, not a target — but while pinned it is always
        // visible, so it stays tappable to release.
        ignoring: !visible,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            // Padding outside the chip widens the target without bloating it.
            padding: const EdgeInsets.all(8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: pinned
                    ? DashTheme.accent
                    : Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(999),
                border: pinned
                    ? null
                    : Border.all(color: DashTheme.ink.withValues(alpha: 0.35)),
              ),
              child: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 20,
                color: pinned ? DashTheme.bg : DashTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DashTheme.surface,
      alignment: Alignment.center,
      child: Icon(Icons.photo_library_outlined,
          size: 96, color: DashTheme.inkFaint),
    );
  }
}
