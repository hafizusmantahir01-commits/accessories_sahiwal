import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../data/history_repository.dart';

/// Owner-only: every change with who did it (owner or partner) and when.
class ActivityHistoryScreen extends ConsumerStatefulWidget {
  const ActivityHistoryScreen({super.key});

  @override
  ConsumerState<ActivityHistoryScreen> createState() => _ActivityHistoryScreenState();
}

class _ActivityHistoryScreenState extends ConsumerState<ActivityHistoryScreen> {
  String? _entity; // null = everything
  String _who = 'all'; // all | owner | partner

  static const _entities = <(String?, String)>[
    (null, 'All'),
    ('product', 'Products'),
    ('sale', 'Sales'),
    ('purchase', 'Purchases'),
    ('opening_stock', 'Opening stock'),
    ('profile', 'Users'),
  ];

  @override
  Widget build(BuildContext context) {
    final filter = HistoryFilter(entity: _entity);
    final log = ref.watch(activityLogProvider(filter));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Activity history')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                for (final (value, label) in _entities) ...[
                  ChoiceChip(label: Text(label), selected: _entity == value, onSelected: (_) => setState(() => _entity = value)),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('Everyone')),
                ButtonSegment(value: 'owner', label: Text('Owner')),
                ButtonSegment(value: 'partner', label: Text('Partner')),
              ],
              selected: {_who},
              onSelectionChanged: (s) => setState(() => _who = s.first),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(activityLogProvider(filter).future),
              child: AsyncView<List<ActivityEntry>>(
                value: log,
                onRetry: () => ref.invalidate(activityLogProvider(filter)),
                data: (all) {
                  final list = all.where((e) => _who == 'all' || e.actorRole == _who).toList();
                  if (list.isEmpty) {
                    return ListView(children: const [EmptyState(icon: Icons.history, title: 'Nothing recorded yet')]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final e = list[i];
                      final color = e.isWarning ? AppTheme.danger : (e.byPartner ? AppTheme.warning : theme.colorScheme.primary);
                      return Card3D(
                        tilt: false,
                        radius: 14,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            IconBadge3D(icon: e.icon, color: color, size: 40),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(e.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Wrap(
                                    spacing: 8,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      StatusChip(
                                        '${e.actorName} · ${e.byPartner ? 'Partner' : (e.actorRole == 'owner' ? 'Owner' : 'System')}',
                                        color: e.byPartner ? AppTheme.warning : null,
                                      ),
                                      Text(BizTime.dateTime(e.at), style: theme.textTheme.bodySmall),
                                    ],
                                  ),
                                  for (final d in e.details)
                                    Padding(padding: const EdgeInsets.only(top: 4), child: Text(d, style: theme.textTheme.bodySmall)),
                                  if ((e.reason ?? '').isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text('Reason: ${e.reason}',
                                          style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
