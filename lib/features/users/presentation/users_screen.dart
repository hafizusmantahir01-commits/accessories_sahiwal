import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../data/users_repository.dart';

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Users & permissions')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(context: context, builder: (_) => const _CreatePartnerDialog()),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add partner'),
      ),
      body: AsyncView<List<ManagedUser>>(
        value: users,
        onRetry: () => ref.invalidate(usersProvider),
        data: (list) => ListView(
          children: [
            PageBody(
              maxWidth: 820,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Partners can view sales and stock only. Purchase costs, profit, suppliers and settings are never sent '
                    'to partner devices.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final u in list) ...[_UserCard(user: u), const SizedBox(height: 12)],
                  const SizedBox(height: 72),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends ConsumerWidget {
  const _UserCard({required this.user});
  final ManagedUser user;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, String done) async {
    try {
      await action();
      ref.invalidate(usersProvider);
      if (context.mounted) context.showSuccess(done);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(usersRepositoryProvider);
    final u = user;
    return SectionCard(
      title: u.fullName.isEmpty ? u.email : u.fullName,
      trailing: StatusChip(
        u.isOwner ? 'Owner' : (!u.isActive ? 'Partner · Inactive' : (u.fullAccess ? 'Partner · Full access' : 'Partner · Active')),
        color: u.isOwner ? null : (u.isActive ? Colors.green.shade700 : Colors.grey),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(u.email),
          Text('Last sign-in: ${u.lastSignInAt == null ? 'never' : BizTime.dateTime(u.lastSignInAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          if (!u.isOwner) ...[
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Account active'),
              subtitle: const Text('Turning off signs the partner out everywhere and blocks login.'),
              value: u.isActive,
              onChanged: (v) => _run(context, ref, () async {
                await repo.setAccess(u, active: v);
                await repo.setLoginEnabled(u.id, v);
              }, v ? 'Partner activated.' : 'Partner deactivated.'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Full access (like owner)'),
              subtitle: const Text('Products, prices, stock, purchases, cost and profit. '
                  'Cannot manage users or the private password. Everything is recorded in Activity history.'),
              value: u.fullAccess,
              onChanged: u.isActive
                  ? (v) => _run(context, ref, () => repo.setFullAccess(u.id, v),
                      v ? 'Full access given.' : 'Full access removed.')
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Can create sales'),
              subtitle: const Text('Record sales and receive payment.'),
              value: u.canCreateSale,
              onChanged: u.isActive
                  ? (v) => _run(context, ref, () => repo.setAccess(u, canCreateSale: v), 'Permission updated.')
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Can change sale prices / discounts'),
              value: u.canOverridePrice,
              onChanged: u.isActive
                  ? (v) => _run(context, ref, () => repo.setAccess(u, canOverridePrice: v), 'Permission updated.')
                  : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out everywhere'),
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        title: 'Revoke sessions?', message: 'The partner must sign in again on every device.');
                    if (ok && context.mounted) {
                      await _run(context, ref, () => repo.revokeSessions(u.id), 'Sessions revoked.');
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.password),
                  label: const Text('Reset password'),
                  onPressed: () async {
                    final pass = await _askPassword(context);
                    if (pass != null && context.mounted) {
                      await _run(context, ref, () => repo.resetPassword(u.id, pass),
                          'Password reset. Share it with the partner privately.');
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<String?> _askPassword(BuildContext context) {
    final controller = TextEditingController();
    final form = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New password'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password (min 8)'),
            validator: Validators.password,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(ctx, controller.text);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}

class _CreatePartnerDialog extends ConsumerStatefulWidget {
  const _CreatePartnerDialog();

  @override
  ConsumerState<_CreatePartnerDialog> createState() => _CreatePartnerDialogState();
}

class _CreatePartnerDialogState extends ConsumerState<_CreatePartnerDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(usersRepositoryProvider).createPartner(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
          );
      ref.invalidate(usersProvider);
      if (!mounted) return;
      context.showSuccess('Partner account created with view-only access.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add partner'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (v) => Validators.required(v, 'Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email (login)'),
                validator: Validators.email,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Temporary password'),
                validator: Validators.password,
              ),
              const SizedBox(height: 8),
              Text(
                'The partner starts with view-only access to sales and stock. Ask them to change the password after first sign-in.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _create, child: const Text('Create account')),
      ],
    );
  }
}
