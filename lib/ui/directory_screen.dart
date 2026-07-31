import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/directory_controller.dart';
import '../models/directory_entry.dart';
import 'theme.dart';
import 'widgets/directory_list.dart';

/// The full-screen phone/email directory, opened from the dashboard's directory
/// column. People are shown in a grouped, multi-column grid so many fit legibly
/// on a 1080p panel. Pointer-navigable (USB mouse).
class DirectoryScreen extends StatelessWidget {
  const DirectoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dir = context.watch<DirectoryController>();

    return Scaffold(
      backgroundColor: DashTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 32, 48, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(offline: !dir.online),
              const SizedBox(height: 28),
              Expanded(
                child: dir.hasEntries
                    ? _DirectoryGrid(groups: dir.groups)
                    : const _EmptyState(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.offline});
  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _BackButton(),
        const SizedBox(width: 24),
        Text(
          'DIRECTORY',
          style: TextStyle(
            color: DashTheme.accent,
            fontSize: 40,
            fontWeight: FontWeight.w800,
            letterSpacing: 5,
          ),
        ),
        const Spacer(),
        if (offline)
          Row(
            children: [
              Icon(Icons.cloud_off, color: DashTheme.offline, size: 24),
              const SizedBox(width: 10),
              Text(
                'showing last update',
                style: TextStyle(color: DashTheme.inkFaint, fontSize: 20),
              ),
            ],
          ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DashTheme.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).maybePop(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back, color: DashTheme.ink, size: 30),
              const SizedBox(width: 12),
              Text(
                'Back',
                style: TextStyle(
                  color: DashTheme.ink,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Groups laid out as fixed-width blocks that wrap into columns; the whole set
/// scrolls vertically if it overflows.
class _DirectoryGrid extends StatelessWidget {
  const _DirectoryGrid({required this.groups});
  final List<DirectoryGroup> groups;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Wrap(
        spacing: 40,
        runSpacing: 40,
        children: [
          for (final g in groups)
            SizedBox(width: 440, child: DirectoryGroupBlock(group: g)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.contacts_outlined, size: 96, color: DashTheme.inkFaint),
          const SizedBox(height: 20),
          Text(
            'No directory entries',
            style: TextStyle(color: DashTheme.inkFaint, fontSize: 26),
          ),
        ],
      ),
    );
  }
}
