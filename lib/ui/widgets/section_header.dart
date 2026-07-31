import 'package:flutter/material.dart';

import '../theme.dart';

/// A consistent accent-colored column heading, with an optional right-aligned
/// detail (e.g. the calendar's date range).
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: TextStyle(
            color: DashTheme.accent,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.5,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: TextStyle(
              color: DashTheme.inkFaint,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
