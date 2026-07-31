import 'package:flutter/material.dart';

import '../../models/directory_entry.dart';
import '../theme.dart';

/// Shared rendering for a group of directory contacts, used by both the
/// dashboard side column (compact) and the full Directory screen (roomy).
class DirectoryGroupBlock extends StatelessWidget {
  const DirectoryGroupBlock({
    super.key,
    required this.group,
    this.compact = false,
  });

  final DirectoryGroup group;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.only(bottom: compact ? 5 : 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: DashTheme.accent,
                width: compact ? 2 : 3,
              ),
            ),
          ),
          child: Text(
            group.name.toUpperCase(),
            style: TextStyle(
              color: DashTheme.inkSoft,
              fontSize: compact ? 14 : 24,
              fontWeight: FontWeight.w700,
              letterSpacing: compact ? 1.5 : 2,
            ),
          ),
        ),
        SizedBox(height: compact ? 8 : 16),
        ...group.people.map(
          (p) => PersonTile(person: p, compact: compact),
        ),
      ],
    );
  }
}

/// One person: name, optional role, then phone/email contact lines.
class PersonTile extends StatelessWidget {
  const PersonTile({super.key, required this.person, this.compact = false});

  final DirectoryEntry person;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 10 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: DashTheme.ink,
              fontSize: compact ? 17 : 28,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          if (!compact && person.role != null && person.role!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                person.role!,
                style: TextStyle(color: DashTheme.inkFaint, fontSize: 19),
              ),
            ),
          SizedBox(height: compact ? 2 : 6),
          if (person.phone != null && person.phone!.isNotEmpty)
            _ContactLine(
              icon: Icons.phone_outlined,
              text: person.phone!,
              compact: compact,
            ),
          if (person.email != null && person.email!.isNotEmpty)
            _ContactLine(
              icon: Icons.mail_outline,
              text: person.email!,
              compact: compact,
            ),
        ],
      ),
    );
  }
}

class _ContactLine extends StatelessWidget {
  const _ContactLine({
    required this.icon,
    required this.text,
    required this.compact,
  });

  final IconData icon;
  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: compact ? 14 : 22, color: DashTheme.accent),
          SizedBox(width: compact ? 7 : 12),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DashTheme.inkSoft,
                fontSize: compact ? 14 : 22,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
