import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../data/auth_repository.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _form = GlobalKey<FormState>();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    if (!_form.currentState!.validate()) return;
    try {
      await ref.read(authRepositoryProvider).updatePassword(_pass.text);
      _pass.clear();
      _confirm.clear();
      if (mounted) context.showSuccess('Password changed.');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileOrNullProvider);
    final email = ref.watch(supabaseProvider).auth.currentUser?.email;
    return Scaffold(
      appBar: AppBar(title: const Text('My account')),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: 'Profile',
                child: Column(
                  children: [
                    InfoRow('Name', profile?.fullName.isNotEmpty == true ? profile!.fullName : '—'),
                    InfoRow('Role', profile?.roleLabel ?? '—'),
                    if (email != null) InfoRow('Email', email),
                    if (profile?.isPartner == true) ...[
                      InfoRow('Can create sales', profile!.canCreateSale ? 'Yes' : 'No'),
                      InfoRow('Can change sale prices', profile.canOverridePrice ? 'Yes' : 'No'),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Change password',
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _pass,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'New password'),
                        validator: Validators.password,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirm,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Confirm new password'),
                        validator: (v) => v != _pass.text ? 'Passwords do not match' : null,
                      ),
                      const SizedBox(height: 16),
                      BusyButton(label: 'Update password', onPressed: _changePassword),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
                onPressed: () async {
                  final ok = await confirmDialog(context, title: 'Sign out?', message: 'You will need to sign in again.');
                  if (ok) await ref.read(authRepositoryProvider).signOut();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
