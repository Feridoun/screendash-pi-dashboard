import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/rota.dart';
import '../theme.dart';

/// The rota for the next few days: one row per doctor, in the order the rota
/// sheet lists them, and a column per day, each cell a dot that says the
/// whole story from across the room and a word or the hours from a few steps
/// closer.
///
/// It is a table so the eye can run down a column — who is in tomorrow — as
/// easily as along a row. The name column sizes to the longest name the team
/// has, capped, and the days share the rest equally.
///
/// The count is whatever the rotation brought, and the card has to fit
/// whatever height it is given — the lower half of the right-hand column at
/// the board's geometry — without hiding anyone, because a doctor missing from
/// the wall reads as "not in", which is the one thing this card must never say
/// by accident. So it measures, and picks the roomiest type scale whose rows
/// fit. The roomiest gives each row two lines: the role under the name, and
/// how to reach them under the day; the tighter ones are a single line, and a
/// long day ("Meeting 10–12 · phone") scales down rather than wrapping. A
/// short role in brackets after the name on the sheet ("Dr A Khan (Cons)")
/// survives at every scale.
class RotaCard extends StatelessWidget {
  const RotaCard({super.key, required this.days, this.today});

  /// The days to show, soonest first. Empty means no rota.
  final List<RotaDay> days;

  /// Which column to mark as today, if any; a weekend shows only days ahead.
  final DateTime? today;

  /// Cap on the name column, so one long name can't squeeze the days out.
  static const double nameMax = 175;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty || days.every((d) => d.people.isEmpty)) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          'Rota not available',
          style: TextStyle(color: DashTheme.inkFaint, fontSize: 20),
        ),
      );
    }

    final rows = _Row.from(days);
    final todayIso = today == null ? null : RotaFeed.isoDate(today!);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = _Scale.choose(rows.length, constraints.maxHeight);
        return Table(
          columnWidths: {
            0: const MinColumnWidth(
                IntrinsicColumnWidth(), FixedColumnWidth(nameMax)),
            for (var i = 1; i <= days.length; i++) i: const FlexColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                const SizedBox(height: _Scale.header),
                for (final d in days)
                  _DayHeader(day: d, isToday: d.date == todayIso),
              ],
            ),
            for (final r in rows)
              TableRow(
                children: [
                  _NameCell(row: r, scale: scale),
                  for (final p in r.cells)
                    p == null
                        ? const SizedBox.shrink()
                        : _DayCell(person: p, scale: scale),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// One doctor across the shown days. The roster can differ between days at a
/// rotation changeover — someone's `Until` falls mid-window — so a cell may be
/// empty; the row order is the first day's, with anyone new appended.
class _Row {
  const _Row({required this.name, required this.role, required this.cells});

  final String name;
  final String? role;
  final List<RotaPerson?> cells;

  static List<_Row> from(List<RotaDay> days) {
    final order = <String>[];
    final byName = <String, List<RotaPerson?>>{};
    for (var i = 0; i < days.length; i++) {
      for (final p in days[i].people) {
        final cells = byName.putIfAbsent(p.name, () {
          order.add(p.name);
          return List<RotaPerson?>.filled(days.length, null);
        });
        cells[i] = p;
      }
    }
    return [
      for (final name in order)
        _Row(
          name: name,
          role: byName[name]!.firstWhere((p) => p != null)!.role,
          cells: byName[name]!,
        ),
    ];
  }
}

/// A type scale for a row: how tall it is and how big its texts are. A role
/// or contact size of zero means that second line is not drawn.
class _Scale {
  const _Scale(this.row, this.name, this.role, this.status, this.contact);

  final double row;
  final double name;
  final double role;
  final double status;
  final double contact;

  bool get twoLine => role > 0;

  /// The day-name row above the table.
  static const double header = 22;

  static const roomy = _Scale(38, 19, 13, 16, 12);
  static const standard = _Scale(30, 17, 0, 15, 0);
  static const dense = _Scale(25, 15, 0, 13, 0);
  static const tight = _Scale(21, 13, 0, 11, 0);

  /// Roomiest first.
  static const List<_Scale> preference = [roomy, standard, dense, tight];

  /// The first scale in [preference] whose rows fit under the header in
  /// [maxHeight]. An unbounded height takes the roomiest; a height nothing
  /// fits takes the tightest and overflows rather than dropping anyone.
  static _Scale choose(int count, double maxHeight) {
    for (final scale in preference) {
      if (header + count * scale.row <= maxHeight) return scale;
    }
    return preference.last;
  }
}

/// "MON 22" over each day column, brighter for today.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.isToday});

  final RotaDay day;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _Scale.header,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            DateFormat('EEE d').format(day.day).toUpperCase(),
            maxLines: 1,
            style: TextStyle(
              color: isToday ? DashTheme.ink : DashTheme.inkFaint,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// The name, with the role under it when the scale has room. Sets the row's
/// height; the other cells centre on it.
class _NameCell extends StatelessWidget {
  const _NameCell({required this.row, required this.scale});

  final _Row row;
  final _Scale scale;

  @override
  Widget build(BuildContext context) {
    final role = row.role;
    return SizedBox(
      height: scale.row,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The name is the one thing that may ellipsise, and only once the
          // column has hit its cap.
          Text(
            row.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: DashTheme.ink,
              fontSize: scale.name,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          if (scale.twoLine && role != null && role.isNotEmpty)
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DashTheme.inkFaint,
                fontSize: scale.role,
                fontWeight: FontWeight.w500,
                height: 1.1,
              ),
            ),
        ],
      ),
    );
  }
}

/// The dot, what the day is, and how to reach them. Scaled down rather than
/// wrapped when it is long: a long caveat costs size, never a third line.
class _DayCell extends StatelessWidget {
  const _DayCell({required this.person, required this.scale});

  final RotaPerson person;
  final _Scale scale;

  /// A cell leads with the caveat when there is one: "Meeting 10–12" says
  /// more than "8–6" does about a day with a meeting in it, and there is no
  /// room for both.
  String get _headline {
    final detail = person.detail;
    return detail == null || detail.isEmpty ? person.label : detail;
  }

  @override
  Widget build(BuildContext context) {
    final off = person.status == RotaStatus.off;
    final colour = _colourFor(person.status);
    final contact = person.contact?.isNotEmpty == true ? person.contact! : null;

    final headline = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: _headline,
              style: TextStyle(
                color: off ? DashTheme.inkFaint : colour,
                fontWeight: FontWeight.w700,
              ),
            ),
            // On a single line the contact rides along after the headline.
            if (contact != null && !scale.twoLine)
              TextSpan(
                text: ' · $contact',
                style: TextStyle(
                  color: DashTheme.inkFaint,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        maxLines: 1,
        style: TextStyle(
          fontSize: scale.status,
          height: 1.1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          _StatusDot(colour: colour, hollow: off),
          const SizedBox(width: 7),
          Expanded(
            child: scale.twoLine && contact != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      headline,
                      Text(
                        contact,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: DashTheme.inkFaint,
                          fontSize: scale.contact,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                        ),
                      ),
                    ],
                  )
                : headline,
          ),
        ],
      ),
    );
  }
}

Color _colourFor(RotaStatus status) => switch (status) {
      RotaStatus.present => DashTheme.online,
      RotaStatus.partial => DashTheme.partial,
      RotaStatus.away => DashTheme.offline,
      RotaStatus.off => DashTheme.inkFaint,
    };

/// The across-the-room signal: filled for a status, hollow for "not their day".
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.colour, required this.hollow});

  final Color colour;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? Colors.transparent : colour,
        border: hollow ? Border.all(color: colour, width: 1.5) : null,
      ),
    );
  }
}
