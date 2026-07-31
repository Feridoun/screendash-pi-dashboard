import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// The wall clock: time on the left, weekday over date on the right. Lives at
/// the top of the calendar column, on the column's own surface — so unlike the
/// old floating overlay it needs no scrim or plate to stay readable.
class ClockHeader extends StatefulWidget {
  const ClockHeader({super.key});

  @override
  State<ClockHeader> createState() => _ClockHeaderState();
}

class _ClockHeaderState extends State<ClockHeader> {
  late Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Tick twice a minute — enough that the displayed minute is never stale by
    // more than 30s, and that the date rolls over promptly at midnight.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          DateFormat('h:mm a').format(_now),
          style: const TextStyle(
            color: DashTheme.ink,
            fontSize: 34,
            fontWeight: FontWeight.w600,
            height: 1.0,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              DateFormat('EEEE').format(_now),
              style: const TextStyle(
                color: DashTheme.inkSoft,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            Text(
              DateFormat('d MMM y').format(_now),
              style: const TextStyle(
                color: DashTheme.inkFaint,
                fontSize: 18,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
