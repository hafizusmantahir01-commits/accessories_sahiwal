import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/three_d.dart';
import '../data/security_repository.dart';

/// Owner only: approve/block phones and computers, see login alerts.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  bool _markedSeen = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      ref.invalidate(devicesProvider);
      ref.invalidate(securityEventsProvider);
      ref.invalidate(securitySummaryProvider);
      if (mounted) context.showSuccess(done);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  void _markSeenOnce() {
    if (_markedSeen) return;
    _markedSeen = true;
    Future.microtask(() async {
      try {
        await ref.read(securityRepositoryProvider).markSeen();
        ref.invalidate(securitySummaryProvider);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final events = ref.watch(securityEventsProvider);
    final summary = ref.watch(securitySummaryProvider);
    final approval = summary.hasValue ? summary.requireValue.approvalRequired : true;
    final repo = ref.read(securityRepositoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices & security'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(securityEventsProvider);
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          PageBody(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.phonelink_lock),
                    title: const Text('New devices need my approval'),
                    subtitle: const Text('A new phone/computer cannot see or change anything until you approve it.'),
                    value: approval,
                    onChanged: (v) async {
                      if (!v) {
                        final ok = await confirmDialog(context,
                            title: 'Turn off device approval?',
                            message: 'Any device with a correct password will work without your approval.',
                            confirmLabel: 'Turn off',
                            destructive: true);
                        if (!ok) return;
                      }
                      await _run(() => repo.setApprovalRequired(v), v ? 'Device approval is on.' : 'Device approval is off.');
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Text('Devices', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                AsyncView<List<DeviceInfo>>(
                  value: devices,
                  onRetry: () => ref.invalidate(devicesProvider),
                  data: (list) => list.isEmpty
                      ? const EmptyState(icon: Icons.devices, title: 'No devices yet')
                      : Column(children: [for (final d in list) _DeviceTile(device: d, onRun: _run)]),
                ),
                const SizedBox(height: 20),
                Text('Security alerts', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                AsyncView<List<SecurityEvent>>(
                  value: events,
                  onRetry: () => ref.invalidate(securityEventsProvider),
                  data: (list) {
                    if (list.any((e) => !e.seen)) _markSeenOnce();
                    if (list.isEmpty) return const EmptyState(icon: Icons.shield_outlined, title: 'No alerts');
                    return Column(
                      children: [
                        for (final e in list)
                          Card(
                            color: e.seen ? null : AppTheme.danger.withValues(alpha: 0.06),
                            child: ListTile(
                              leading: Icon(e.icon, color: e.isDanger ? AppTheme.danger : AppTheme.steel),
                              title: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text([
                                BizTime.dateTime(e.at),
                                if (e.who.isNotEmpty) e.who,
                                if (e.device.isNotEmpty) e.device,
                                if (e.ip.isNotEmpty) 'IP ${e.ip}',
                              ].join(' · ')),
                              trailing: e.seen ? null : const StatusChip('New', color: AppTheme.danger),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device, required this.onRun});
  final DeviceInfo device;
  final Future<void> Function(Future<void> Function() action, String done) onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final repo = ref.read(securityRepositoryProvider);
    final color = switch (d.status) {
      'approved' => AppTheme.success,
      'blocked' => AppTheme.danger,
      _ => AppTheme.warning,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card3D(
        tilt: false,
        radius: 14,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge3D(
                  icon: d.label.contains('Android') || d.label.contains('iPhone') ? Icons.smartphone : Icons.computer,
                  color: color,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${d.userName} · ${d.userRole == 'owner' ? 'Owner' : 'Partner'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${d.label.isEmpty ? 'Unknown device' : d.label}${d.isCurrent ? ' (this device)' : ''}'),
                      Text('Last used ${BizTime.dateTime(d.lastSeen)}${d.ip.isNotEmpty ? ' · IP ${d.ip}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                StatusChip(
                  switch (d.status) { 'approved' => 'Approved', 'blocked' => 'Blocked', _ => 'Waiting' },
                  color: color,
                ),
              ],
            ),
            if (!d.isCurrent) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (d.status != 'approved')
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Approve'),
                      onPressed: () => onRun(() => repo.setDeviceStatus(d.id, 'approved'), 'Device approved.'),
                    ),
                  if (d.status != 'blocked')
                    OutlinedButton.icon(
                      icon: const Icon(Icons.block),
                      label: const Text('Block'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                      onPressed: () async {
                        final ok = await confirmDialog(context,
                            title: 'Block this device?',
                            message: '${d.label} (${d.userName}) will not be able to open the app.',
                            confirmLabel: 'Block',
                            destructive: true);
                        if (ok) await onRun(() => repo.setDeviceStatus(d.id, 'blocked'), 'Device blocked.');
                      },
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                    onPressed: () async {
                      final ok = await confirmDialog(context,
                          title: 'Remove this device?',
                          message: 'If it signs in again it will need approval again.',
                          confirmLabel: 'Remove');
                      if (ok) await onRun(() => repo.deleteDevice(d.id), 'Device removed.');
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
