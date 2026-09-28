import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// The wall clock: weekday, date and time stacked, largest first. Lives at the
/// top-left of the calendar column with the outlook alongside it, on the
/// column's own surface — so unlike the old floating overlay it needs no scrim
/// or plate to stay readable.
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
    // One left-aligned stack, read top to bottom: which day it is, which date,
    // what time. Weekday and time carry the same weight so both read from
    // across the room, with the date a quieter line between them. Stacking
    // rather than spreading them across the column leaves the whole right-hand
    // side to the outlook.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEEE').format(_now),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: DashTheme.ink,
            fontSize: 34,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          DateFormat('d MMM y').format(_now),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: DashTheme.inkSoft,
            fontSize: 20,
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          DateFormat('h:mm a').format(_now),
          maxLines: 1,
          style: const TextStyle(
            color: DashTheme.ink,
            fontSize: 34,
            fontWeight: FontWeight.w600,
            height: 1.0,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
