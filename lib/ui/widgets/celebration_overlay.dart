import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/celebration_controller.dart';
import '../../models/celebration.dart';
import '../theme.dart';

/// A brief burst of confetti and a headline when something new lands on the
/// board — a new notice, or a batch of photos someone just emailed in.
///
/// Pointer-transparent throughout: the dashboard underneath stays clickable
/// while it plays, and it never needs dismissing by hand.
class CelebrationOverlay extends StatelessWidget {
  const CelebrationOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final celebration = context.watch<CelebrationController>().current;

    return IgnorePointer(
      child: celebration == null
          ? const SizedBox.shrink()
          // Keyed by serial so a second arrival mid-animation restarts the
          // burst instead of inheriting the spent one.
          : _Burst(
              key: ValueKey(celebration.serial),
              celebration: celebration,
            ),
    );
  }
}

class _Burst extends StatefulWidget {
  const _Burst({super.key, required this.celebration});

  final Celebration celebration;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: AppConfig.celebrationDuration,
  )..forward();

  late final List<_Confetto> _pieces =
      _Confetto.spray(widget.celebration.serial);

  /// The card swells in quickly, holds, then fades with the confetti still
  /// falling behind it.
  late final Animation<double> _cardIn = CurvedAnimation(
    parent: _anim,
    curve: const Interval(0.0, 0.10, curve: Curves.easeOutBack),
  );
  late final Animation<double> _fadeOut = CurvedAnimation(
    parent: _anim,
    curve: const Interval(0.80, 1.0, curve: Curves.easeIn),
  );

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final opacity = 1.0 - _fadeOut.value;
        if (opacity <= 0) return const SizedBox.shrink();
        return Opacity(
          opacity: opacity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The confetti repaints every frame; the card underneath doesn't.
              RepaintBoundary(
                child: CustomPaint(
                  painter: _ConfettiPainter(
                    pieces: _pieces,
                    t: _anim.value,
                  ),
                ),
              ),
              Center(
                child: Transform.scale(
                  scale: 0.6 + 0.4 * _cardIn.value,
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
      // Built once, not per frame — only its scale and opacity animate.
      child: _CelebrationCard(celebration: widget.celebration),
    );
  }
}

/// The headline itself: an icon, what happened, and how much of it.
class _CelebrationCard extends StatelessWidget {
  const _CelebrationCard({required this.celebration});

  final Celebration celebration;

  @override
  Widget build(BuildContext context) {
    final (icon, headline, detail) = switch (celebration.kind) {
      CelebrationKind.notice => (
          Icons.campaign_outlined,
          'NEW NOTICE',
          'just posted to the board',
        ),
      CelebrationKind.photos => (
          Icons.photo_camera_outlined,
          celebration.count == 1 ? 'NEW PHOTO' : 'NEW PHOTOS',
          celebration.count == 1
              ? 'one just arrived'
              : '${celebration.count} just arrived',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
      decoration: BoxDecoration(
        color: DashTheme.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: DashTheme.accent, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 40,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72, color: DashTheme.accent),
          const SizedBox(height: 18),
          Text(
            headline,
            style: TextStyle(
              color: DashTheme.accent,
              fontSize: 46,
              fontWeight: FontWeight.w800,
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            detail,
            style: TextStyle(color: DashTheme.inkSoft, fontSize: 24),
          ),
        ],
      ),
    );
  }
}

/// One piece of confetti, launched from the middle of the screen.
///
/// Everything is expressed in fractions of the viewport so the burst scales
/// with the panel instead of being tuned to one resolution.
class _Confetto {
  const _Confetto({
    required this.angle,
    required this.speed,
    required this.size,
    required this.spin,
    required this.color,
    required this.drift,
  });

  final double angle; // radians, launch direction
  final double speed; // viewport heights per unit time
  final double size; // fraction of the viewport's shorter side
  final double spin; // turns over the whole animation
  final Color color;
  final double drift; // sideways sway, fraction of viewport width

  /// A deterministic spray, seeded by the celebration's serial so successive
  /// bursts differ from each other but any one burst is reproducible in tests.
  static List<_Confetto> spray(int seed) {
    final rng = math.Random(seed);
    // Warm amber through to the status greens: the board's own palette, so a
    // burst reads as part of the dashboard rather than a stock animation.
    const palette = [
      DashTheme.accent,
      DashTheme.online,
      DashTheme.offline,
      DashTheme.ink,
    ];

    return List.generate(AppConfig.celebrationParticles, (i) {
      // Fan the launch angles evenly over the full circle, then jitter, so the
      // burst never clumps to one side the way pure random would.
      final base = (i / AppConfig.celebrationParticles) * 2 * math.pi;
      return _Confetto(
        angle: base + (rng.nextDouble() - 0.5) * 0.6,
        speed: 0.5 + rng.nextDouble() * 0.7,
        size: 0.012 + rng.nextDouble() * 0.014,
        spin: 1 + rng.nextDouble() * 3,
        color: palette[rng.nextInt(palette.length)],
        drift: (rng.nextDouble() - 0.5) * 0.25,
      );
    });
  }
}

/// Paints the spray at animation time [t] (0..1): outward from the centre,
/// pulled down by gravity, tumbling as it goes.
class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.pieces, required this.t});

  final List<_Confetto> pieces;
  final double t;

  /// Viewport heights per unit time squared. Tuned so a piece launched sideways
  /// clears the bottom edge around the time the overlay fades.
  static const double _gravity = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final unit = size.shortestSide;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in pieces) {
      final x = cx +
          math.cos(p.angle) * p.speed * t * size.width * 0.6 +
          p.drift * t * size.width;
      final y = cy +
          math.sin(p.angle) * p.speed * t * size.height * 0.6 +
          0.5 * _gravity * t * t * size.height;

      // Cheap cull: skip anything that has already left the panel.
      if (y > size.height + unit || x < -unit || x > size.width + unit) continue;

      final side = p.size * unit;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t * 2 * math.pi);
      paint.color = p.color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: side,
            // Rectangles rather than squares: a tumbling oblong reads as paper.
            height: side * 0.55,
          ),
          Radius.circular(side * 0.15),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.t != t || !identical(old.pieces, pieces);
}
