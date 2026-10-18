import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/care_plus_theme.dart';

class OperationsShell extends StatelessWidget {
  const OperationsShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    (Icons.insights_outlined, Icons.insights, 'Overview'),
    (Icons.bar_chart_outlined, Icons.bar_chart, 'Reports'),
    (Icons.event_note_outlined, Icons.event_note, 'Bookings'),
    (Icons.groups_outlined, Icons.groups, 'Team'),
    (Icons.inventory_2_outlined, Icons.inventory_2, 'Stock'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: BottomAppBar(
        height: 68,
        padding: EdgeInsets.zero,
        color: context.scheme.surface,
        child: Row(
          children: [
            for (var i = 0; i < _destinations.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => navigationShell.goBranch(
                    i,
                    initialLocation: i == navigationShell.currentIndex,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        index == i ? _destinations[i].$2 : _destinations[i].$1,
                        size: 21,
                        color: index == i ? context.scheme.primary : context.care.inkFaint,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _destinations[i].$3,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: index == i ? FontWeight.w700 : FontWeight.w500,
                          color: index == i ? context.scheme.primary : context.care.inkFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
